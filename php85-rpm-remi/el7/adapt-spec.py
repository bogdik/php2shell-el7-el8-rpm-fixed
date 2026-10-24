#!/usr/bin/env python3
"""Turn a Remi EL8 system php.spec into an EL7 SCL spec. rpm 4.11."""
import sys

HEADER = """\
%if 0%{?scl:1}
%scl_package php
%global _sysconfdir /etc/opt/%{scl_vendor}/%{scl}
%global _localstatedir /var/opt/%{scl_vendor}/%{scl}
%global _httpd_moddir %{_root_libdir}/httpd/modules
%global _httpd_confdir %{_root_sysconfdir}/httpd/conf.d
%global _httpd_modconfdir %{_root_sysconfdir}/httpd/conf.modules.d
%global _httpd_apxs %{_root_bindir}/apxs
%else
%global pkg_name          %{name}
%global _root_sysconfdir  %{_sysconfdir}
%global _root_bindir      %{_bindir}
%global _root_sbindir     %{_sbindir}
%global _root_includedir  %{_includedir}
%global _root_libdir      %{_libdir}
%global _root_prefix      %{_prefix}
%global _root_initddir    %{_initddir}
%global _root_datadir     %{_datadir}
%endif

"""

SED_FPM = """\
sed -e 's:/run:%{_localstatedir}/run:g' \\
    -e 's:/var/log:%{_localstatedir}/log:g' \\
    -e 's:/etc:%{_sysconfdir}:g' \\
    -i $RPM_BUILD_ROOT%{_sysconfdir}/php-fpm.conf
"""

SED_WWW = """\
sed -e 's:/run/php-fpm:%{_localstatedir}/run/php-fpm:g' \\
    -e 's:/var/lib:%{_localstatedir}/lib:g' \\
    -e 's:/var/log:%{_localstatedir}/log:g' \\
    -i $RPM_BUILD_ROOT%{_sysconfdir}/php-fpm.d/www.conf
"""

SED_UNIT = """\
sed -e 's:/run:%{_localstatedir}/run:g' \\
    -e 's:/usr/sbin:%{_sbindir}:g' \\
    -e 's:php-fpm.service:%{?scl_prefix}php-fpm.service:g' \\
    -i $RPM_BUILD_ROOT%{_unitdir}/%{?scl_prefix}php-fpm.service
"""

SED_HTTPD = """\
sed -e 's:/run/php-fpm:%{_localstatedir}/run/php-fpm:g' \\
    -e 's/libphp\\.so/lib%{scl}.so/' \\
    -i $RPM_BUILD_ROOT%{_httpd_confdir}/%{scl}-php.conf \\
       $RPM_BUILD_ROOT%{_httpd_modconfdir}/20-%{scl}.conf
"""

SED_NGINX = """\
sed -e 's:/run/php-fpm:%{_localstatedir}/run/php-fpm:g' \\
    -e 's/upstream php-fpm/upstream %{scl}-php-fpm/' \\
    -i $RPM_BUILD_ROOT%{_root_sysconfdir}/nginx/conf.d/%{?scl_prefix}php-fpm.conf
"""

SED_NGINX_DEFAULT = """\
sed -e 's/fastcgi_pass   php-fpm/fastcgi_pass   %{scl}-php-fpm/' \\
    -i $RPM_BUILD_ROOT%{_root_sysconfdir}/nginx/default.d/%{scl}-php.conf
"""

LINKS = """\
%if 0%{?scl:1}
install -m 755 -d $RPM_BUILD_ROOT%{_root_bindir}
ln -s %{_bindir}/php       $RPM_BUILD_ROOT%{_root_bindir}/%{scl}
ln -s %{_bindir}/php-cgi   $RPM_BUILD_ROOT%{_root_bindir}/%{scl}-cgi
ln -s %{_bindir}/phar.phar $RPM_BUILD_ROOT%{_root_bindir}/%{scl_prefix}phar
ln -s %{_bindir}/phpdbg    $RPM_BUILD_ROOT%{_root_bindir}/%{scl_prefix}phpdbg
%endif
"""

BUILD_ENV = """\
. /opt/rh/devtoolset-11/enable
export PKG_CONFIG_PATH=/opt/php-el7-libs/lib/pkgconfig:/opt/php-openssl11/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
export CPPFLAGS="-I/opt/php-el7-libs/include${CPPFLAGS:+ $CPPFLAGS}"
export LDFLAGS="-Wl,-rpath,/opt/php-el7-libs/lib -Wl,-rpath,/usr/lib64/openssl11${LDFLAGS:+ $LDFLAGS}"
"""


def prefix_dep(line):
    if line.startswith("Recommends:"):
        return "#" + line
    if not line.startswith(("Requires:", "Provides:", "Obsoletes:", "Conflicts:")):
        return line
    out = []
    i = 0
    token = "php"
    while True:
        j = line.find(token, i)
        if j < 0:
            out.append(line[i:])
            break
        prev = line[j - 1] if j else ""
        nxt = line[j + 3] if j + 3 < len(line) else ""
        already = line[max(0, j - 14):j].endswith("scl_prefix}")
        word = (prev == "" or not (prev.isalnum() or prev == "_")) and (
            nxt == "" or not (nxt.isalnum() or nxt == "_")
        )
        if word and not already:
            out.append(line[i:j])
            out.append("%{?scl_prefix}php")
        else:
            out.append(line[i:j + 3])
        i = j + 3
    return "".join(out)


def transform(text):
    if "%scl_package php" in text:
        raise SystemExit("spec already has an SCL header")
    lines = text.splitlines(keepends=True)
    out = []
    header = False
    build_env = False
    saw = {k: 0 for k in (
        "name", "libso", "modconf", "unit", "run", "trigger", "fpmconf", "www", "links"
    )}
    i = 0
    while i < len(lines):
        line = lines[i]
        if not header and line.startswith("%global apiver"):
            out.append(HEADER)
            header = True
        if line.startswith("%transfiletriggerin "):
            out.append("# rpm 4.11 has no file triggers; the install script restarts FPM\n")
            saw["trigger"] += 1
            i += 2
            continue
        if line.startswith("%build") and line.strip() == "%build" and not build_env:
            out.append(line)
            out.append(BUILD_ENV)
            build_env = True
            i += 1
            continue
        if line.strip() == "Name: php":
            line = "Name: %{?scl_prefix}php\n"
            saw["name"] += 1
        line = line.replace(
            "BuildRequires: openssl-devel >= 1.0.2",
            "BuildRequires: openssl11-devel",
        )
        line = line.replace(
            "Requires: openssl-devel%{?_isa} >= 1.0.2",
            "Requires: openssl11-devel%{?_isa}",
        )
        line = prefix_dep(line)
        exact = {
            "install -m 755 build-apache/libs/libphp.so $RPM_BUILD_ROOT%{_httpd_moddir}/libphp.so\n":
                "install -m 755 build-apache/libs/libphp.so $RPM_BUILD_ROOT%{_httpd_moddir}/lib%{scl}.so\n",
            "install -D -m 644 %{SOURCE9} $RPM_BUILD_ROOT%{_httpd_modconfdir}/20-php.conf\n":
                "install -D -m 644 %{SOURCE9} $RPM_BUILD_ROOT%{_httpd_modconfdir}/20-%{scl}.conf\n",
            "install -D -m 644 %{SOURCE1} $RPM_BUILD_ROOT%{_httpd_confdir}/php.conf\n":
                "install -D -m 644 %{SOURCE1} $RPM_BUILD_ROOT%{_httpd_confdir}/%{scl}-php.conf\n",
            "install -m 755 -d $RPM_BUILD_ROOT/run/php-fpm\n":
                "install -m 755 -d $RPM_BUILD_ROOT%{_localstatedir}/run/php-fpm\n",
            "install -m 755 -d $RPM_BUILD_ROOT%{_sysconfdir}/logrotate.d\n":
                "install -m 755 -d $RPM_BUILD_ROOT%{_root_sysconfdir}/logrotate.d\n",
            "install -m 644 %{SOURCE7} $RPM_BUILD_ROOT%{_sysconfdir}/logrotate.d/php-fpm\n":
                "install -m 644 %{SOURCE7} $RPM_BUILD_ROOT%{_root_sysconfdir}/logrotate.d/%{?scl_prefix}php-fpm\n",
            "install -m 755 -d $RPM_BUILD_ROOT%{_sysconfdir}/systemd/system/php-fpm.service.d\n":
                "install -m 755 -d $RPM_BUILD_ROOT%{_root_sysconfdir}/systemd/system/%{?scl_prefix}php-fpm.service.d\n",
            "install -Dm 644 %{SOURCE6}  $RPM_BUILD_ROOT%{_unitdir}/php-fpm.service\n":
                "install -Dm 644 %{SOURCE6}  $RPM_BUILD_ROOT%{_unitdir}/%{?scl_prefix}php-fpm.service\n",
            "install -Dm 644 %{SOURCE12} $RPM_BUILD_ROOT%{_sysconfdir}/systemd/system/httpd.service.d/php-fpm.conf\n":
                "install -Dm 644 %{SOURCE12} $RPM_BUILD_ROOT%{_root_sysconfdir}/systemd/system/httpd.service.d/%{?scl_prefix}php-fpm.conf\n",
            "install -Dm 644 %{SOURCE12} $RPM_BUILD_ROOT%{_sysconfdir}/systemd/system/nginx.service.d/php-fpm.conf\n":
                "install -Dm 644 %{SOURCE12} $RPM_BUILD_ROOT%{_root_sysconfdir}/systemd/system/nginx.service.d/%{?scl_prefix}php-fpm.conf\n",
            "install -Dm 644 %{SOURCE12} $RPM_BUILD_ROOT%{_unitdir}/httpd.service.d/php-fpm.conf\n":
                "install -Dm 644 %{SOURCE12} $RPM_BUILD_ROOT%{_root_sysconfdir}/systemd/system/httpd.service.d/%{?scl_prefix}php-fpm.conf\n",
            "install -Dm 644 %{SOURCE12} $RPM_BUILD_ROOT%{_unitdir}/nginx.service.d/php-fpm.conf\n":
                "install -Dm 644 %{SOURCE12} $RPM_BUILD_ROOT%{_root_sysconfdir}/systemd/system/nginx.service.d/%{?scl_prefix}php-fpm.conf\n",
            "install -D -m 644 %{SOURCE13} $RPM_BUILD_ROOT%{_sysconfdir}/nginx/conf.d/php-fpm.conf\n":
                "install -D -m 644 %{SOURCE13} $RPM_BUILD_ROOT%{_root_sysconfdir}/nginx/conf.d/%{?scl_prefix}php-fpm.conf\n",
            "install -D -m 644 %{SOURCE14} $RPM_BUILD_ROOT%{_sysconfdir}/nginx/default.d/php.conf\n":
                "install -D -m 644 %{SOURCE14} $RPM_BUILD_ROOT%{_root_sysconfdir}/nginx/default.d/%{scl}-php.conf\n",
            "%systemd_post php-fpm.service\n":
                "%systemd_post %{?scl_prefix}php-fpm.service\n",
            "%systemd_preun php-fpm.service\n":
                "%systemd_preun %{?scl_prefix}php-fpm.service\n",
            "%{_httpd_moddir}/libphp.so\n":
                "%{_httpd_moddir}/lib%{scl}.so\n",
            "%config(noreplace) %{_httpd_modconfdir}/20-php.conf\n":
                "%config(noreplace) %{_httpd_modconfdir}/20-%{scl}.conf\n",
            "%config(noreplace) %{_httpd_confdir}/php.conf\n":
                "%config(noreplace) %{_httpd_confdir}/%{scl}-php.conf\n",
            "%config(noreplace) %{_sysconfdir}/logrotate.d/php-fpm\n":
                "%config(noreplace) %{_root_sysconfdir}/logrotate.d/%{?scl_prefix}php-fpm\n",
            "%config(noreplace) %{_sysconfdir}/nginx/conf.d/php-fpm.conf\n":
                "%config(noreplace) %{_root_sysconfdir}/nginx/conf.d/%{?scl_prefix}php-fpm.conf\n",
            "%config(noreplace) %{_sysconfdir}/nginx/default.d/php.conf\n":
                "%config(noreplace) %{_root_sysconfdir}/nginx/default.d/%{scl}-php.conf\n",
            "%{_unitdir}/php-fpm.service\n":
                "%{_unitdir}/%{?scl_prefix}php-fpm.service\n",
            "%config(noreplace) %{_sysconfdir}/systemd/system/httpd.service.d/php-fpm.conf\n":
                "%config(noreplace) %{_root_sysconfdir}/systemd/system/httpd.service.d/%{?scl_prefix}php-fpm.conf\n",
            "%config(noreplace) %{_sysconfdir}/systemd/system/nginx.service.d/php-fpm.conf\n":
                "%config(noreplace) %{_root_sysconfdir}/systemd/system/nginx.service.d/%{?scl_prefix}php-fpm.conf\n",
            "%{_unitdir}/httpd.service.d/php-fpm.conf\n":
                "%config(noreplace) %{_root_sysconfdir}/systemd/system/httpd.service.d/%{?scl_prefix}php-fpm.conf\n",
            "%{_unitdir}/nginx.service.d/php-fpm.conf\n":
                "%config(noreplace) %{_root_sysconfdir}/systemd/system/nginx.service.d/%{?scl_prefix}php-fpm.conf\n",
            "%dir %{_sysconfdir}/systemd/system/php-fpm.service.d\n":
                "%dir %{_root_sysconfdir}/systemd/system/%{?scl_prefix}php-fpm.service.d\n",
            "%dir %ghost /run/php-fpm\n":
                "%dir %{_localstatedir}/run/php-fpm\n",
        }
        if line in exact:
            key = "libso" if "libphp.so" in line else "modconf" if "20-php" in line or "php.conf" in line else "unit" if "php-fpm.service" in line or "systemd" in line else "run"
            saw[key] += 1
            line = exact[line]
        out.append(line)
        if line.startswith("install -m 644 %{SOURCE4} "):
            out.append(SED_FPM)
            saw["fpmconf"] += 1
        elif line.startswith("install -m 644 %{SOURCE5} "):
            out.append(SED_WWW)
            saw["www"] += 1
        elif "nginx/conf.d/%{?scl_prefix}php-fpm.conf" in line and line.startswith("install "):
            out.append(SED_NGINX)
        elif "nginx/default.d/%{scl}-php.conf" in line and line.startswith("install "):
            out.append(SED_NGINX_DEFAULT)
        elif line.startswith("install -Dm 644 %{SOURCE6} "):
            out.append(SED_UNIT)
            out.append(SED_HTTPD)
        elif line.startswith('TESTCMD="$RPM_BUILD_ROOT%{_bindir}/php --no-php-ini"'):
            out.insert(len(out) - 1, LINKS)
            saw["links"] += 1
        elif line.strip() == "%{_bindir}/php":
            out.append("%{_root_bindir}/%{scl}\n")
        elif line.strip() == "%{_bindir}/php-cgi":
            out.append("%{_root_bindir}/%{scl}-cgi\n")
        elif line.strip() == "%{_bindir}/phar.phar":
            out.append("%{_root_bindir}/%{scl_prefix}phar\n")
        elif line.strip() == "%{_bindir}/phpdbg":
            out.append("%{_root_bindir}/%{scl_prefix}phpdbg\n")
        i += 1
    missing = [k for k, v in (
        ("header", header), ("build", build_env),
        ("name", saw["name"]), ("fpmconf", saw["fpmconf"]), ("www", saw["www"]),
        ("links", saw["links"]), ("trigger", saw["trigger"]), ("libso", saw["libso"]),
    ) if not v]
    if missing:
        raise SystemExit("adapt-spec missed: " + " ".join(missing))
    text = "".join(out)
    if "\nRecommends:" in text or text.startswith("Recommends:"):
        raise SystemExit("a Recommends line survived")
    if "%transfiletrigger" in text:
        raise SystemExit("a file trigger survived")
    if "/etc/opt/%{scl_vendor}/%{scl}" not in text:
        raise SystemExit("SCL config path missing")
    return text


def main():
    src, dst = sys.argv[1], sys.argv[2]
    text = transform(open(src, encoding="utf-8").read())
    open(dst, "w", encoding="utf-8").write(text)


if __name__ == "__main__":
    main()
