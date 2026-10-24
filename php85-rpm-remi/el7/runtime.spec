Name: php85-runtime
Version: 8.5
Release: 3.el7.remi.local
Summary: Software Collection runtime for php85
License: GPLv2+
Requires: scl-utils
Requires: php-el7-libs = 1.0-1.el7.local
Requires: openssl11-libs
BuildArch: x86_64

%description
Directory layout and enable script for the php85 Software Collection.

%install
mkdir -p %{buildroot}/opt/remi/php85/root
mkdir -p %{buildroot}/etc/opt/remi/php85
mkdir -p %{buildroot}/var/opt/remi/php85
mkdir -p %{buildroot}/etc/scl/prefixes
cat > %{buildroot}/opt/remi/php85/enable << 'EOF'
export PATH=/opt/remi/php85/root/usr/bin:/opt/remi/php85/root/usr/sbin${PATH:+:${PATH}}
export LD_LIBRARY_PATH=/opt/remi/php85/root/usr/lib64:/opt/php-el7-libs/lib:/usr/lib64/openssl11${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
export MANPATH=/opt/remi/php85/root/usr/share/man:${MANPATH}
EOF
echo /opt/remi > %{buildroot}/etc/scl/prefixes/php85

%files
/opt/remi/php85/enable
/etc/scl/prefixes/php85
%dir /opt/remi/php85
%dir /opt/remi/php85/root
%dir /etc/opt/remi/php85
%dir /var/opt/remi/php85
