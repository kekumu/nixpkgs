{ fetchurl, stdenv, curl, openssl, zlib, expat, perl, python, gettext, cpio
, gnugrep, gzip, openssh
, asciidoc, texinfo, xmlto, docbook2x, docbook_xsl, docbook_xml_dtd_45
, libxslt, tcl, tk, makeWrapper, libiconv
, svnSupport, subversionClient, perlLibs, smtpPerlLibs, gitwebPerlLibs
, guiSupport
, withManual ? true
, pythonSupport ? true
, sendEmailSupport
, darwin
}:

let
  version = "2.10.1";
  svn = subversionClient.override { perlBindings = true; };
in

stdenv.mkDerivation {
  name = "git-${version}";

  src = fetchurl {
    url = "https://www.kernel.org/pub/software/scm/git/git-${version}.tar.xz";
    sha256 = "1ijd1b6szvfw0dmqa3dz1m5g5hbkl9xkb86a9qcjrz0w0vwjvhx9";
  };

  hardeningDisable = [ "format" ];

  patches = [
    ./docbook2texi.patch
    ./symlinks-in-bin.patch
    ./git-sh-i18n.patch
    ./ssh-path.patch
    ./ssl-cert-file.patch
  ];

  postPatch = ''
    for x in connect.c git-gui/lib/remote_add.tcl ; do
      substituteInPlace "$x" \
        --subst-var-by ssh "${openssh}/bin/ssh"
    done
  '';

  buildInputs = [curl openssl zlib expat gettext cpio makeWrapper libiconv perl]
    ++ stdenv.lib.optionals withManual [ asciidoc texinfo xmlto docbook2x
         docbook_xsl docbook_xml_dtd_45 libxslt ]
    ++ stdenv.lib.optionals guiSupport [tcl tk]
    ++ stdenv.lib.optionals stdenv.isDarwin [ darwin.Security ];


  # required to support pthread_cancel()
  NIX_LDFLAGS = stdenv.lib.optionalString (!stdenv.cc.isClang) "-lgcc_s"
              + stdenv.lib.optionalString (stdenv.isFreeBSD) "-lthr";

  # without this, git fails when trying to check for /etc/gitconfig existence
  propagatedSandboxProfile = stdenv.lib.sandbox.allowDirectoryList "/etc";

  makeFlags = "prefix=\${out} PERL_PATH=${perl}/bin/perl SHELL_PATH=${stdenv.shell} "
      + (if pythonSupport then "PYTHON_PATH=${python}/bin/python" else "NO_PYTHON=1")
      + (if stdenv.isSunOS then " INSTALL=install NO_INET_NTOP= NO_INET_PTON=" else "")
      + (if stdenv.isDarwin then " NO_APPLE_COMMON_CRYPTO=1" else " sysconfdir=/etc/ ");

  # build git-credential-osxkeychain if darwin
  postBuild = stdenv.lib.optionalString stdenv.isDarwin ''
    pushd $PWD/contrib/credential/osxkeychain/
    make
    popd
  '';

  # FIXME: "make check" requires Sparse; the Makefile must be tweaked
  # so that `SPARSE_FLAGS' corresponds to the current architecture...
  #doCheck = true;

  installFlags = "NO_INSTALL_HARDLINKS=1";

  preInstall = stdenv.lib.optionalString stdenv.isDarwin ''
    mkdir -p $out/bin
    mv $PWD/contrib/credential/osxkeychain/git-credential-osxkeychain $out/bin
  '';

  postInstall =
    ''
      notSupported() {
        unlink $1 || true
      }

      # Install git-subtree.
      pushd contrib/subtree
      make
      make install ${stdenv.lib.optionalString withManual "install-doc"}
      popd
      rm -rf contrib/subtree

      # Install contrib stuff.
      mkdir -p $out/share/git
      mv contrib $out/share/git/
      mkdir -p $out/share/emacs/site-lisp
      ln -s "$out/share/git/contrib/emacs/"*.el $out/share/emacs/site-lisp/
      mkdir -p $out/etc/bash_completion.d
      ln -s $out/share/git/contrib/completion/git-completion.bash $out/etc/bash_completion.d/
      ln -s $out/share/git/contrib/completion/git-prompt.sh $out/etc/bash_completion.d/

      # grep is a runtime dependency, need to patch so that it's found
      substituteInPlace $out/libexec/git-core/git-sh-setup \
          --replace ' grep' ' ${gnugrep}/bin/grep' \
          --replace ' egrep' ' ${gnugrep}/bin/egrep'

      # Fix references to the perl binary. Note that the tab character
      # in the patterns is important.
      sed -i -e 's|	perl -ne|	${perl}/bin/perl -ne|g' \
             -e 's|	perl -e|	${perl}/bin/perl -e|g' \
             $out/libexec/git-core/{git-am,git-submodule}

      # Fix references to gettext.
      substituteInPlace $out/libexec/git-core/git-sh-i18n \
          --subst-var-by gettext ${gettext}

      # gzip (and optionally bzip2, xz, zip) are runtime dependencies for
      # gitweb.cgi, need to patch so that it's found
      sed -i -e "s|'compressor' => \['gzip'|'compressor' => ['${gzip}/bin/gzip'|" \
          $out/share/gitweb/gitweb.cgi
      # Give access to CGI.pm and friends (was removed from perl core in 5.22)
      for p in ${stdenv.lib.concatStringsSep " " gitwebPerlLibs}; do
          sed -i -e "/use CGI /i use lib \"$p/lib/perl5/site_perl\";" \
              "$out/share/gitweb/gitweb.cgi"
      done

      # Also put git-http-backend into $PATH, so that we can use smart
      # HTTP(s) transports for pushing
      ln -s $out/libexec/git-core/git-http-backend $out/bin/git-http-backend
    ''

   + (if svnSupport then

      ''# wrap git-svn
        gitperllib=$out/lib/perl5/site_perl
        for i in ${builtins.toString perlLibs} ${svn.out}; do
          gitperllib=$gitperllib:$i/lib/perl5/site_perl
        done
        wrapProgram $out/libexec/git-core/git-svn     \
                     --set GITPERLLIB "$gitperllib"   \
                     --prefix PATH : "${svn.out}/bin" ''
       else '' # replace git-svn by notification script
        notSupported $out/libexec/git-core/git-svn
       '')

   + (if sendEmailSupport then
      ''# wrap git-send-email
        gitperllib=$out/lib/perl5/site_perl
        for i in ${builtins.toString smtpPerlLibs}; do
          gitperllib=$gitperllib:$i/lib/perl5/site_perl
        done
        wrapProgram $out/libexec/git-core/git-send-email \
                     --set GITPERLLIB "$gitperllib" ''
       else '' # replace git-send-email by notification script
        notSupported $out/libexec/git-core/git-send-email
       '')

   + stdenv.lib.optionalString withManual ''# Install man pages and Info manual
       make -j $NIX_BUILD_CORES -l $NIX_BUILD_CORES PERL_PATH="${perl}/bin/perl" cmd-list.made install install-info \
         -C Documentation ''

   + (if guiSupport then ''
       # Wrap Tcl/Tk programs
       for prog in bin/gitk libexec/git-core/{git-gui,git-citool,git-gui--askpass}; do
         sed -i -e "s|exec 'wish'|exec '${tk}/bin/wish'|g" \
                -e "s|exec wish|exec '${tk}/bin/wish'|g" \
                "$out/$prog"
       done
     '' else ''
       # Don't wrap Tcl/Tk, replace them by notification scripts
       for prog in bin/gitk libexec/git-core/git-gui; do
         notSupported "$out/$prog"
       done
     '')
   + stdenv.lib.optionalString stdenv.isDarwin ''
    # enable git-credential-osxkeychain by default if darwin
    cat > $out/etc/gitconfig << EOF
[credential]
	helper = osxkeychain
EOF
  '';


  enableParallelBuilding = true;

  meta = {
    homepage = http://git-scm.com/;
    description = "Distributed version control system";
    license = stdenv.lib.licenses.gpl2;

    longDescription = ''
      Git, a popular distributed version control system designed to
      handle very large projects with speed and efficiency.
    '';

    platforms = stdenv.lib.platforms.all;
    maintainers = with stdenv.lib.maintainers; [ peti the-kenny wmertens ];
  };
}
