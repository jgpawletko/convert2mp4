%define name	convert2mp4
%define version	2.0
%define release	1.dlts%{?dist}
%define dlibdir	/usr/local/dlib/%{name}

Summary:	Convert video file to mp4 for HIDVL streaming.
Name:		%{name}
Version:	%{version}
Release:	%{release}
License:	NYU DLTS
Vendor:		NYU DLTS (rasan@nyu.edu)
Group:		Applications/Multimedia
URL:		https://github.com/rrasch/%{name}
BuildRoot:	%{_tmppath}/%{name}-root
BuildArch:	noarch
BuildRequires:	git
#Requires:	ams-tools
Requires:	ffmpeg >= 2.1.6
#Requires:	libmp4v2 = 2.0.0
Requires:	mediainfo
Requires:	perl-Image-ExifTool
Requires:	vcs

%description
%{summary}

%prep

%build

%install
rm -rf %{buildroot}

#git clone %{url}/tags/%{version} %{buildroot}%{dlibdir}
git clone %{url}.git %{buildroot}%{dlibdir}
rm -rf %{buildroot}%{dlibdir}/.git
find %{buildroot}%{dlibdir} -type d | xargs chmod 0755
find %{buildroot}%{dlibdir} -type f | xargs chmod 0644
chmod 0755 %{buildroot}%{dlibdir}/bin/*

mkdir -p %{buildroot}%{_bindir}
ln -s ../..%{dlibdir}/bin/convert2mp4.pl %{buildroot}%{_bindir}/convert2mp4
ln -s ../..%{dlibdir}/bin/create-mp4.rb  %{buildroot}%{_bindir}/create-mp4

rm -r %{buildroot}%{dlibdir}/templates

%clean
rm -rf %{buildroot}

%files
%defattr(-, root, dlib)
%dir %{dlibdir}
%config(noreplace) %{dlibdir}/conf
%{dlibdir}/presets
%{dlibdir}/bin
%{dlibdir}/doc
%{_bindir}/*

%changelog