#!/usr/bin/env perl
#
# Convert video file to mp4 for streaming.
#
# References:
# 
# http://flowplayer.org/forum/7/12671
# http://sites.google.com/site/linuxencoding/x264-ffmpeg-mapping
# http://rob.opendot.cl/index.php/useful-stuff/ffmpeg-x264-encoding-guide/
# http://rob.opendot.cl/index.php/useful-stuff/x264-to-ffmpeg-option-mapping/
# https://www.virag.si/2012/01/web-video-encoding-tutorial-with-ffmpeg-0-9/
# https://documentation.apple.com/en/finalcutpro/usermanual/index.html#chapter=106%26section=6%26tasks=true
# https://wiki.libav.org/Encoding/aac
# https://trac.ffmpeg.org/wiki/Encode/AAC
# https://trac.ffmpeg.org/wiki/Encode/H.264
#
# Author: Rasan Rasch <rasan@nyu.edu>

use strict;
use warnings;
use AppConfig qw(:expand);
use Cwd qw(abs_path);
use Data::Dumper;
use File::Basename;
use File::Copy;
use File::Temp qw(tempdir);
use File::Path;
use Getopt::Std;
use IO::CaptureOutput qw(capture_exec_combined);
use List::Util qw(min);
use Log::Log4perl qw(get_logger :no_extra_logdie_message);
use Log::Log4perl::Level;
use Time::Duration;
use Sys::Hostname;
use XML::LibXML;


# Default config values:
# Config options not set in conf/convert2mp4.conf or
# on command line will be set to the values below.
my %opt = (
	# Path to ffmpeg
	path_ffmpeg => "/usr/bin/ffmpeg",

	# Tool to check whether file is FMS streamable.
	path_flvcheck => "/usr/bin/flvcheck",

	# Tool to display technical metadata for media file.
	path_mediainfo => "/usr/bin/mediainfo",

	# ffmpeg tool to extract techmd from media file.
	path_ffprobe => "/usr/bin/ffprobe",
	
	# Tool to extract techmd, specifically clean
	# aperture quicktime movie settings.
	path_exiftool => "/usr/bin/exiftool",

	# Directory for intermediate files
	path_tmpdir => "/tmp",

	# Video encoding options
	video_preset => "default",

	profiles_path => ["profiles-movie-scenes.xml"],

	# Flash media server config
	fms_enabled     => 0,
	fms_url         => "rtmp://localhost/vod/media/",
	fms_content_dir => "/opt/adobe/ams/applications/vod/media",
	fms_html_dir    => "/opt/adobe/ams/webroot",

	# Flowplayer display width
	flowplayer_height => 480,

	# append suffix to output file names
	name_suffix => "s",
);

my $main_cfg_file = $ENV{CONVERT2MP4_CONF} || "conf/convert2mp4.conf";

############################################################

$SIG{HUP} = 'IGNORE';

# find application directory
my $this_script = abs_path($0);
my $bin_dir     = dirname($this_script);
my $app_home    = dirname($bin_dir);

Log::Log4perl->init("$app_home/conf/log.conf");

my $log = get_logger();

$SIG{__WARN__} = sub { $log->logdie(@_) };

my $host = hostname();

my $is_cygwin = $^O =~ /cygwin/i;

# Need this to enable large file support in exiftool
my $exif_cfg_file = "$app_home/conf/exiftool.conf";

# template html for connecting to flash media server
my $tmpl_file = "$app_home/templates/fms.html.in";

my $cfg_file = AppConfig->new({GLOBAL => {EXPAND => EXPAND_ALL}});
my $cfg_cmdl = AppConfig->new({GLOBAL => {EXPAND => EXPAND_ALL}});

# define variables for AppConfig 
for my $cfg ($cfg_file, $cfg_cmdl)
{
	for my $opt_name (keys %opt)
	{
		my $def = "$opt_name=s";
		$def .= '@' if is_array($opt{$opt_name});
		$cfg->define($def);
	}
}

# Read options from file.
$main_cfg_file = "$app_home/$main_cfg_file";
if (-f $main_cfg_file) {
	$cfg_file->file($main_cfg_file);
}

# Define some boolean flags (after reading config file).
$cfg_cmdl->define("help|h!");
$cfg_cmdl->define("force|f!");
$cfg_cmdl->define("test|t!");
$cfg_cmdl->define("quiet|q!");

# Read audio delay option from cmd line
$cfg_cmdl->define("adelay|a=f");

$cfg_cmdl->define("keyframe_timecode_file|k=s");

$cfg_cmdl->define("watermark|w=s");

# Read options from cmdline.
$cfg_cmdl->args();

if ($cfg_cmdl->get("quiet"))
{
	$log->level($WARN);
}

# override default values
for my $cfg ($cfg_file, $cfg_cmdl)
{
	my %varlist = $cfg->varlist(".");
	$log->trace('varlist: ', Dumper(\%varlist));
	for my $opt_name (keys %varlist)
	{
		my $val = $cfg->get($opt_name);
		$opt{$opt_name} = $val unless is_empty_array($val) || !$val;
	}
}

$log->trace("Script invocation: $this_script ", join(" ", @ARGV));

$log->trace('Options: ', Dumper(\%opt));

$log->trace("Size of \@ARGV: " . @ARGV);

if ($opt{help}) {
	usage(\%opt);
} elsif (!@ARGV) {
	usage(\%opt, "Missing input file.");
}

# Check that programs exist.
for my $opt_name (keys %opt)
{
	if ($opt_name =~ /^path_(.*)$/)
	{
		$log->logdie("Path $1:$opt{$opt_name} doesn't exist")
		  if !-e $opt{$opt_name};
	}
}

my ($input_file, $output_prefix) = @ARGV;

if (! -f $input_file) {
	$log->logdie("Input file '$input_file' doesn't exist.");
}
$log->debug("Input file: $input_file");

# Generate output file prefix from input file path if
# no output file prefix given on cmd line.
if (!$output_prefix) {
	my ($filename, $dirname, $suffix) = fileparse($input_file, qr/\.[^.]*/);
	$output_prefix = $dirname . $filename;
}
$log->debug("Output prefix: $output_prefix");

my $output_dir = dirname($output_prefix);
if (! -d $output_dir) {
	mkpath($output_dir);
}

my $tmpdir = tempdir(
	DIR     => $opt{path_tmpdir},
	CLEANUP => 1,
);

$ENV{TMPDIR} = $tmpdir;

# set ffmpeg preset directory
$ENV{FFMPEG_DATADIR} ||= "$app_home/presets";

my %wm_coord = (
	TL => "10:10",
	TR => "main_w-overlay_w-10:10",
	BL => "10:main_h-overlay_h-10",
	BR => "main_w-overlay_w-10:main_h-overlay_h-10",
	C  => "(main_w-overlay_w-10)/2:(main_h-overlay_h-10)/2",
);

my $wm_file;
my $wm_orientation;
my $wm_width_percent;

# Parse and validate watermark options
if ($opt{watermark})
{
	($wm_file, $wm_orientation, $wm_width_percent) =
	  split(':', $opt{watermark});

	if (!$wm_file) {
		$log->logdie("You must specify a watermark file.");
	} elsif(!-f $wm_file) {
		$log->logdie("Watermark file '$wm_file' doesn't exist.");
	}

	# set defaults
	$wm_orientation   ||= "BR";
	$wm_width_percent ||= 40;

	if ($wm_orientation !~ /^(TL|TR|BL|BR|C)$/i)
	{
		$log->logdie("Incorrect watermark orientation "
			. "'$wm_orientation'. Must be one of TL|TR|BL|BR|C");
	}
}


my $timecode_str;
if ($opt{keyframe_timecode_file})
{
	if (-f $opt{keyframe_timecode_file})
	{
		my @timecodes;
		open(my $in, $opt{keyframe_timecode_file})
		  or $log->logdie("can't open $opt{keyframe_timecode_file}: $!");
		while (my $line = <$in>)
		{
			chomp($line);
			next if $line =~ /^#/ || $line =~ /^$/;
			if ($line =~ /^(\d{2}:\d{2}:\d{2}\.\d{3})$/)
			{
				push(@timecodes, $1);
			}
			else
			{
				$log->warn("Invalid timecode entry: $line");
			}
		}
		close($in);
		$timecode_str = join(",", @timecodes);
	}
	else
	{
		$log->logdie(
			"Timecode file $opt{keyframe_timecode_file} doesn't exist.");
	}
}
$log->debug("Timecodes: $timecode_str") if $timecode_str;

my @mediainfo_cmd = ($opt{path_mediainfo}, "-f",  "--Language=raw");

my $minfo =
  XML::LibXML->load_xml(
	string => sys(@mediainfo_cmd, "--Output=XML", $input_file));
my $minfo_path = "/Mediainfo/File/track[\@type='Video']";

my $ffprobe =
  XML::LibXML->load_xml(
    string => sys($opt{path_ffprobe}, '-v', 'quiet', '-print_format',
      'xml', '-show_streams', $input_file));
my $ffpath = "/ffprobe/streams/stream[\@codec_type='video']";

my $exif = XML::LibXML->load_xml(
	string => sys(
		$opt{path_exiftool}, '-config', $exif_cfg_file, '-X', $input_file));
($exif) = $exif->findnodes("/rdf:RDF/rdf:Description");

my $track_id = val($minfo, "$minfo_path/ID");
$log->debug("Video Track ID: $track_id");

my $is_track_info;
for my $ns ($exif->findnodes('./namespace::*'))
{
	my $prefix = $ns->getLocalName();
	last if $is_track_info = $prefix =~ /^Track/;
}

my $track_exists;
eval { $track_exists = val($exif, "./Track$track_id:TrackID"); };
if ($@) {
	$log->warn($@);
}

my $ff_video_idx  = val($ffprobe, "$ffpath/\@index");
my $ff_audio_idx  = val($ffprobe, "/ffprobe/streams/stream[\@codec_type='audio']/\@index");
my $real_width   = val($ffprobe, "$ffpath/\@width");
my $real_height  = val($ffprobe, "$ffpath/\@height");
my $pixel_format = val($ffprobe, "$ffpath/\@pix_fmt");
my $par_str      = val($ffprobe, "$ffpath/\@sample_aspect_ratio");
my $par          = str2float($par_str);
my $dar_str      = val($ffprobe, "$ffpath/\@display_aspect_ratio");
my $dar          = str2float($dar_str);
$log->debug("ffprobe Real Width: $real_width");
$log->debug("ffprobe Real Height: $real_height");
$log->debug("ffprobe PAR string: $par_str");
$log->debug(sprintf("ffprobe PAR: %.5f", $par));
$log->debug("ffprobe DAR string: $dar_str");
$log->debug(sprintf("ffprobe DAR: %.5f", $dar));

# if sample and display aspect ratio are undefined in ffprobe
# get value from mediainfo
if ($par_str eq "0:1" && $dar_str eq "0:1")
{
	$par = val($minfo, "$minfo_path/PixelAspectRatio");
	$log->debug("mediainfo PAR: $par");
}

my $src_width  = val($minfo, "$minfo_path/Width_CleanAperture")
  || val($minfo, "$minfo_path/Width");
my $src_height = val($minfo, "$minfo_path/Height_CleanAperture")
  || val($minfo, "$minfo_path/Height");
my $scan_type  = val($minfo, "$minfo_path/ScanType");
my $chroma     = val($minfo, "$minfo_path/ChromaSubsampling");
$log->debug("mediainfo Width: $src_width");
$log->debug("mediainfo Height: $src_height");
$log->debug("Scan Type: $scan_type");
$log->debug("Chroma Subsampling: $chroma");

my $square_width = round_even($src_width * $par);
my $square_height = $src_height;
$log->debug("Square pixel width: ${square_width}x${square_height}");

# if ($sar == 0)
# {
# 	my $dar_str = val($minfo, "$minfo_path/DisplayAspectRatio_String");
# 	my $dar = str2float($dar_str);
# 	my $par = val($minfo, "$minfo_path/PixelAspectRatio");
# 	$sar = $dar / $par;
# 	$log->debug(sprintf("mediainfo DAR: %.5f", $dar));
# 	$log->debug("mediainfo PAR: $par");
# 	$log->debug(sprintf("mediainfo SAR: %.5f", $sar));
# }

my $is_interlaced = $scan_type =~ /interlace/i;

my $flowplayer_width =
  round_even(($opt{flowplayer_height} / $src_height) * $src_width * $par);
$log->debug(
	"Flowplayer Dimensions: ${flowplayer_width}x$opt{flowplayer_height}");

my $calc_crop_width = 1;
my $clean_ap_dimensions = "";
my $prod_ap_dimensions = "";
my $enc_pix_dimensions = "";

if ($track_exists)
{
	$clean_ap_dimensions =
	  val($exif, "./Track$track_id:CleanApertureDimensions");
	$prod_ap_dimensions =
	  val($exif, "./Track$track_id:ProductionApertureDimensions");
	$enc_pix_dimensions =
	  val($exif, "./Track$track_id:EncodedPixelsDimensions");
}

if (!$clean_ap_dimensions)
{
	$calc_crop_width = 0;
	my $clean_ap_width  = val($minfo, "$minfo_path/Width_CleanAperture");
	my $clean_ap_height = val($minfo, "$minfo_path/Height_CleanAperture");
	if ($clean_ap_width && $clean_ap_height)
	{
		$clean_ap_dimensions = $clean_ap_width . 'x' . $clean_ap_height;
	}
	$enc_pix_dimensions =
	    val($minfo, "$minfo_path/Width") . 'x'
	  . val($minfo, "$minfo_path/Height");
}

$log->debug("Clean Aperture Dimensions:      $clean_ap_dimensions");
$log->debug("Production Aperture Dimensions: $prod_ap_dimensions");
$log->debug("Encoded Pixels Dimensions:      $enc_pix_dimensions");

my $crop_filter_params;
if (   $clean_ap_dimensions
	&& $enc_pix_dimensions
	&& $clean_ap_dimensions ne $enc_pix_dimensions)
{
	my ($clean_width, $clean_height) = split(/x/, $clean_ap_dimensions);

	my $crop_width;
	if ($calc_crop_width) {
		$crop_width = round((1 / $par) * $clean_width);
	} else {
		$crop_width = $clean_width;
	}

	my $crop_height = $clean_height;

	my $src_dim  = $src_width  . 'x' . $src_height;
	my $crop_dim = $crop_width . 'x' . $crop_height;

	if ($src_dim ne $crop_dim)
	{
		$log->logdie("Dimensions reported by mediainfo ($src_dim) ",
			" != Crop dimensions ($crop_dim)");
	}

	my $diff_w = $real_width  - $crop_width;
	my $diff_h = $real_height - $crop_height;

	$crop_filter_params =
	    "$crop_width:$crop_height:"
	  . round($diff_w / 2) . ':'
	  . round($diff_h / 2);

	$log->debug("Crop filter paramters: $crop_filter_params");
}

my @output_files = ();

# my $config_file = "$app_home/conf/config.xml";
# my $config = XML::LibXML->load_xml(location => $config_file);
# my @profile_paths = get_values($config, '/config/profiles/path');
my @profile_paths = @{$opt{profiles_path}};
$log->trace("Profiles: ", join(", ", @profile_paths));

my @profiles = ();
for my $profile_xml_file (@profile_paths)
{
	$profile_xml_file = "$app_home/conf/$profile_xml_file"
	  unless $profile_xml_file =~ m|^/|;
	my $profile_cfg = XML::LibXML->load_xml(location => $profile_xml_file);
	push(@profiles, $profile_cfg->findnodes('/profiles/profile'));
}

for my $profile (@profiles)
{
	next unless val($profile, './enabled');

	my $video_device     = val($profile, './device');
	my $video_dimensions = val($profile, './dimensions');
	my $video_bitrate    = val($profile, './vbitrate');
	my $video_bufsize    = val($profile, './vbufsize');
	my $audio_bitrate    = val($profile, './abitrate');

	# set bufsize to double bitrate if not set
	if (!$video_bufsize)
	{
		($video_bufsize = $video_bitrate) =~ s/k$//;
		$video_bufsize *= 2;
		$video_bufsize .= 'k';
	}

	my $h264_profile;
	my $h264_level;
	my $aac_profile;
	if ($video_device && $video_device =~ /mobile/i) {
		$h264_profile  = "main";
		$h264_level    = "3.1";
		# Apple HTTP Live Streaming doesn't seem to work with HE-AAC v2
		$aac_profile   = "aac_he";
	} else {
		$h264_profile  = "high";
		$h264_level    = "4.1";
		$aac_profile   = "aac_low";
	}

	$video_dimensions =~ s/auto/-1/;

	my ($max_width, $max_height) = split("x", $video_dimensions);
	
	my $ratio_w = $max_width  / $square_width;
	my $ratio_h = $max_height / $square_height;
	$log->trace("Ratio width: $ratio_w");
	$log->trace("Ratio height: $ratio_h");

	my $scale_ratio;
	if ($max_width == -1) {
		$scale_ratio = $ratio_h;
	} elsif ($max_height == -1) {
		$scale_ratio = $ratio_w;
	} else {
		$scale_ratio = min($ratio_w, $ratio_h);
	}
	$log->debug("Scale Ratio: $scale_ratio");

	my $width  = round_even($square_width  * $scale_ratio);
	my $height = round_even($square_height * $scale_ratio);

	$video_dimensions = $width . "x" . $height;

	if ($scale_ratio > 1)
	{
		$log->warn("Output dimensions ($video_dimensions) are ",
			"greater than original dimensions ",
			"(${square_width}x${square_height}).");
	}

	$log->debug("New Dimensions: $video_dimensions");

	# Calculate total bitrate
	my $total_bitrate = 0;
	for my $bitrate ($video_bitrate, $audio_bitrate)
	{
		my $rate = $bitrate;
		$rate =~ s/k$//;
		$total_bitrate += $rate;
	}
	$total_bitrate .= "k";
	$log->debug("Total bitrate: $total_bitrate");

	my $output_file = "${output_prefix}_${total_bitrate}";
	$output_file .= "_$video_device" if $video_device;
	$output_file .= "_$opt{name_suffix}" if $opt{name_suffix};
	$output_file .= ".mp4";
	push(@output_files, $output_file);

	if (-f $output_file)
	{
		if ($opt{force})
		{
			$log->info("Force option set, forcing removal of '$output_file'");
			unlink($output_file)
			  or $log->logdie("can't remove $output_file: $!");
		}
		else
		{
			$log->warn("Output file '$output_file' already exists.");
			next;
		}
	}

	$log->debug("Output file: $output_file");

	my $short_name = basename($output_file, ".mp4");
	my $mp4_file   = "$tmpdir/$short_name.mp4";
	my $html_file  = "${output_prefix}_${total_bitrate}.html";

	# Transcode input file to mp4 file.
	my @transcode_cmd;

	my $wm_width = round_even($width * ($wm_width_percent / 100))
	  if $opt{watermark};

	my $video_filter = "";
	$video_filter .=
	  "movie=$wm_file,scale=$wm_width:-1 [watermark]; [in] "
	  if $opt{watermark};
	$video_filter .= "crop=$crop_filter_params," if $crop_filter_params;
	$video_filter .= "scale=$width:$height,setsar=1:1";
	$video_filter .=
	    " [tmp];  [tmp][watermark]"
	  . " overlay=$wm_coord{$wm_orientation} [out]"
	  if $opt{watermark};

	my $force_keyframes = "chapters";
	$force_keyframes .= ",$timecode_str" if $timecode_str;

	@transcode_cmd = ($opt{path_ffmpeg});

	if ($opt{quiet})
	{
		push(
			@transcode_cmd,
			"-nostats",
			"-loglevel" => "warning",
		);
	}

	push(@transcode_cmd, "-i" => $input_file);

	if ($opt{adelay})
	{
		push(
			@transcode_cmd,
			"-itsoffset" => sprintf('%.3f', $opt{adelay}),
			"-i"         => $input_file,
			"-map"       => "0:$ff_video_idx",
			"-map"       => "1:$ff_audio_idx",
		);
	}

	push(@transcode_cmd,
		"-sn",
		"-map_metadata"     => -1,
		"-map_chapters"     => -1,
		"-vcodec"           => "libx264",
		"-profile:v"        => $h264_profile,
		"-level"            => $h264_level,
		"-b:v"              => $video_bitrate,
		"-minrate"          => $video_bitrate,
		"-maxrate"          => $video_bitrate,
		"-bufsize"          => $video_bufsize,
		"-vf"               => $video_filter,
		"-pix_fmt"          => "yuv420p",
		"-force_key_frames" => $force_keyframes,
	);

	push(@transcode_cmd, "-vpre" => $opt{video_preset})
	  if $opt{video_preset};

	if ($is_interlaced)
	{
		$log->debug("Setting ffmpeg to deinterlace video");
		push(@transcode_cmd, "-deinterlace");
	}

	push(@transcode_cmd,
		"-acodec"    => "libfdk_aac",
		"-profile:a" => $aac_profile,
		"-ab"        => $audio_bitrate,
		"-ac"        => 2,
		"-ar"        => 44100,
		"-cutoff"    => 18000,
		"-movflags",
		"+faststart",
		"-threads"   => 0,
	);

	push(@transcode_cmd, "-t" => 30) if $opt{test};
	push(@transcode_cmd, $mp4_file);

	sys(@transcode_cmd);

	# Check to see if file is streamable by flash media server.
	sys($opt{path_flvcheck}, '-n', cygpath($mp4_file));

	$log->debug("Moving $mp4_file to $host:$output_file");
	move($mp4_file, $output_file)
	  or $log->logdie("can't move $mp4_file to $output_file: $!");
}


if ($opt{fms_enabled})
{
	my $is_agent_running = sys("pgrep", "ssh-agent");
	for my $output_file (@output_files)
	{
		my $html_file = $output_file;
		$html_file =~ s/\.mp4$/.html/;
		if (!$opt{force} && -f $html_file) {
			$log->warn("html file $html_file already exists.");
		} else {
			create_fms_html($html_file, $output_file,
				$flowplayer_width, $opt{flowplayer_height});
		}
		if ($is_agent_running)
		{
			sys("scp", $html_file,   $opt{fms_html_dir});
			sys("scp", $output_file, $opt{fms_content_dir});
		}
	}
}


sub round
{
	my $number = shift;
	my $integer = sprintf("%.0f", $number);
	$log->trace("Rounded $number to nearest integer $integer");
	return $integer;
}


sub round_even
{
	my $number = shift;
	my $even_integer = sprintf("%.0f", $number / 2) * 2;
	$log->trace("Rounded $number to nearest even integer $even_integer");
	return $even_integer;
}


sub get_values
{
	my ($root, $expr) = @_;
	return map { $_->string_value } $root->findnodes($expr);
}


sub create_fms_html
{
	my ($html_file, $mp4_file, $flowp_width, $flowp_height) = @_;

	my $tmp_html_file = "$tmpdir/" . basename($html_file);
	
	my $techmd = sys(@mediainfo_cmd, $mp4_file);

	my %replace = (
		MP4_FILE => basename($mp4_file),
		TECHMD   => $techmd,
		FMS_URL  => $opt{fms_url},
		WIDTH    => $flowp_width,
		HEIGHT   => $flowp_height,
	);

	open(my $in, "<$tmpl_file") or $log->logdie("can't open $tmpl_file: $!");
	open(my $out, ">$tmp_html_file")
	  or $log->logdie("can't open $tmp_html_file: $!");
	while (my $line = <$in>)
	{
		for my $search (keys %replace)
		{
			$line =~ s/<!-- $search -->/$replace{$search}/g;
		}
		print $out $line;
	}
	close($in);
	close($out);
	move($tmp_html_file, $html_file)
	  or $log->logdie("can't move $tmp_html_file to $html_file: $!");
}


sub sys
{
	my @cmd = @_;
	my $cmd_str = join(" ", @cmd);
	$log->debug("running command '$cmd_str'");
	my $start_time = time;
	my ($output, $success, $exit_code) = capture_exec_combined(@cmd);
	my $end_time = time;
	$output =~ s/\r/\n/g;  # replace carriage returns with newlines
	$output =~
	  s/[^\x9\xA\xD\x20-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}]+//g
	  if $output =~ /<\?xml version=/;
	my $exit_status = $exit_code >> 8;
	$log->trace("output: $output");
	$log->debug("run time: ", duration_exact($end_time - $start_time));
	if (!$success && !($cmd[0] =~ /^pgrep/ && $exit_status == 1)) {
		$log->logdie("Command '$cmd_str' exited with ",
			"status: $exit_status, output: $output");
	}
	return $output;
}


sub cygpath
{
	my $path = shift;
	if ($is_cygwin) {
		$path = sys('cygpath', '-w', $path);
		chomp($path);
	}
	return $path;
}


sub usage
{
	my ($opt, $msg) = @_;
	select(STDERR);
	my $tab = " " x 8;
	print "\nUsage: $0 [options] <input_file> [<output_prefix>]\n\n",
	  "options:\n\n",
	  "  -h, --help   Print this usage message and exit\n",
	  "  -f, --force  Force removal of output files if they exist\n",
	  "  -t, --test   For testing only encode first 60 seconds of file\n",
	  "  -k, --keyframe_timecode_file=FILE\n",
	  "            Force keyframes at timecodes listed in file\n",
	  "            see an example in doc directory\n",
	  "  -a, --adelay=NUMBER\n",
	  "            Delay audio by this number of seconds\n",
	  "  -w, --watermark=FILE:[ORIENTATION]:[WIDTH_PERCENTAGE]\n",
	  "            Add watermark. Optionally specify orientation\n",
	  "            (TL|TR|BL|BR|C) and width as a percentage of\n",
	  "            output video.\n",
	  "\n",
	  "    ", right_pad("Encoding option"), $tab, "Current value\n",
	  "  ", "=" x 50, "\n";

	for my $opt_name (sort keys %$opt)
	{
		next if $opt_name =~ /^(help|force)$/;
		my $val = $opt->{$opt_name};
		$val = join(", ", @$val) if is_array($val);
		print "  --", right_pad($opt_name), $tab, "($val)\n";
	}
	print "\n";
	if ($msg)
	{
		print "ERROR: $msg\n\n";
		exit(1);
	}
	exit(0);
}


sub is_array
{
	my $val = shift;
	return ref($val) eq "ARRAY";
}


sub is_empty_array
{
	my $val = shift;
	is_array($val) && !@$val;
}


sub right_pad
{
	sprintf("%-20s", shift);
}


sub val
{
	my ($node, $xpath) = @_;
	$log->trace($xpath);
	return $node->findvalue($xpath);
}


sub str2float
{
	my $aspect_ratio = shift;
	$aspect_ratio =~ s,:,/,;
	eval $aspect_ratio;
}

