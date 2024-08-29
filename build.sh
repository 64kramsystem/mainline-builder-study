#!/bin/bash

# shellcheck disable=all

set -u

export LANG=C

update=yes
btype=binary
sign=no
exclude=none
series=jammy
checkbugs=yes
kver="$kver"
metaver="0"
metatime=1672531200
maintainer="Zaphod Beeblebrox <zaphod@betelgeuse-seven.western-spiral-arm.change.me.to.match.signing.key>"
buildargs="-aamd64 -d"
branch=""
clean=no

do_metapackage() {
  KVER=$1
  METAVER=$2
  METATIME="$(date -d @${3} '+UTC %Y-%m-%d %T')"
  VERSION=$(echo ${KVER} | awk -F. '{printf "%d.%02d", $1,$2 }')
  REMOVEME=$4
  REMOVEME=$5
  MAINT=$6
  ABINUM=$7
  REMOVEME=$8
  BINS="${KVER}-${ABINUM}-generic"
  DEPS="linux-headers-${BINS}, linux-image-unsigned-${BINS}, linux-modules-${BINS}"

  echo ">>> Metapackage for generic: MetaVersion: $METAVER, MetaTime: $METATIME"
  [ -d "../meta" ] || mkdir ../meta
  cd ../meta
  cat > metapackage.control <<-EOF
		Section: devel
		Priority: optional
		# Homepage: <enter URL here; no default>
		Standards-Version: 3.9.2

		Package: linux-generic-${VERSION}
		Changelog: changelog
		Version: ${KVER}-${METAVER}
		Maintainer: ${MAINT}
		Depends: ${DEPS}
		Architecture: amd64
		Description: Meta-package which will always depend on the latest packages in a mainline series.
		  This meta package will depend on the latest kernel in a series (eg 5.12.x) and install the
		  dependencies for that kernel.
		  .
		  Example: linux-generic-5.12 will depend on linux-image-unsigned-5.12.x-generic,
		  linux-modules-5.12.x-generic, linux-headers-5.12.x-generic and linux-headers-5.12.x
	EOF
	cat > changelog <<-EOF
		linux-generic-${VERSION} (${KVER}-${METAVER}) ${series}; urgency=low

		  Metapackage for Linux ${VERSION}.x
		  Mainline build at commit: v${KVER}

		 -- ${MAINT}  $(date -R)
	EOF

  mkdir -p "source/usr/share/doc/linux-generic-${VERSION}"
  cat > "source/usr/share/doc/linux-generic-${VERSION}/README" <<-EOF
		This meta-package will always depend on the latest ${VERSION} kernel
		To see which version that is you can execute:

          $ apt-cache depends linux-generic-${VERSION}

        :wq
	EOF

  grep "native" /usr/share/equivs/template/debian/source/format > /dev/null
  native=$?

  if [ "$native" == "0" ]
  then
    echo "Extra-Files: source/usr/share/doc/linux-generic-${VERSION}/README" >> metapackage.control
  else
    tar -C source --sort=name --owner=root:0 --group=root:0 --mtime="$METATIME" -zcf "linux-generic-${VERSION}_${KVER}.orig.tar.gz" .
  fi

  equivs-build metapackage.control

  changesfile="linux-generic-${VERSION}_${KVER}-${METAVER}_source.changes"
  grep "BEGIN PGP SIGNED MESSAGE" "$changesfile" > /dev/null
  signed=$?

  if [ "$signed" != "0" ]
  then
    debsign -m"${MAINT}" "${changesfile}"
  fi

  mv linux-* ../
  cd -
}

__die() {
  local rc=$1; shift
  printf 1>&2 '%s\n' "ERROR: $*"; exit $rc
}

__update_sources() {
  echo -e ">>> Args.... update is $update"
  cd /home/source/

  if [ -z "${branch}" ]
  then
    branch="${kver}"
  fi

  if [ "${update}" == "new" ]
  then
    [ "$(ls -A /home/source)" != "" ] && __die 1 "/home/source must be empty when using 'update=new'"
    echo -e "********\n\nFetching git source from Kernel.org, branch: $branch\n\n********"
    git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
      --branch "${branch}" /home/source --single-branch || __die 1 "Failed to checkout source from kernel.org"
  else
    echo -e "********\n\nCleaning git source tree\n\n********"
    git clean -fdx || __die 1 'git failed'
    git reset --hard HEAD
    if [ "$update" == "yes" ]
    then
      echo -e "********\n\nUpdating git source tree\n\n********"
      git fetch --tags origin
    fi
    echo -e "********\n\nSwitching to ${branch} branch\n\n********"
    git checkout "${branch}" || __die 1 "Tag for '${branch} not found"
  fi
}

echo -e "********\n\nBuild starting\n\n********"

args=( "$@" );
for (( i=0; $i < $# ; i++ ))
do
  arg=${args[$i]}
  if [[ $arg = --*=* ]]
  then
    key=${arg#--}
    val=${key#*=}; key=${key%%=*}
    case "$key" in
      update|sign|exclude|series|checkbugs|maintainer|kver|metaver|metatime|branch|clean)
        printf -v "$key" '%s' "$val" ;;
      *) __die 1 "Unknown flag $arg"
    esac
  else __die 1 "Bad arg $arg"
  fi
done

echo -e ">>> Args.... sign is $sign"
if [ "$sign" == "no" ]
then
  buildargs="$buildargs -uc -ui -us"
else
  buildargs="$buildargs -sa --sign-key=${sign}"
  cp -rp /root/keys /root/.gnupg
  chown -R root:root /root/.gnupg
  chmod 700 /root/.gnupg
fi

cd "$ksrc" || __die 1 "\$ksrc ${ksrc@Q} not found"

# tell git to trust /home/source
git config --global --add safe.directory /home/source

__update_sources

# prep
echo -e "********\n\nRenaming source package and updating control files\n\n********"
debversion=$(date +%Y%m%d%H%M)
abinum=$(echo ${kver:1} | awk -F. '{printf "%02d%02d%02d", $1,$2,$3 }')
sed -i -re "s/(^linux) \(([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)\.[0-9]+\) ([^;]*)(.*)/linux (${kver:1}-${abinum}.${debversion}) ${series}\5/" debian.master/changelog
sed -i -re 's/dwarves \[/dwarves (>=1.21) \[/g' debian.master/control.stub.in

# don't fail if we find no *.ko files in the build dir
sed -i -re 's/zstd -19 --quiet --rm/zstd -19 --rm || true/g' debian/rules.d/2-binary-arch.mk

# revert GCC to v12 on Jammy
echo -e ">>> Downgrade GCC to version 12 on focal"
sed -i -re 's/export gcc\?=.*/export gcc?=gcc-12/' debian/rules.d/0-common-vars.mk

echo -e "********\n\nSetting flavour: generic\n\n********"
sed -i -re "s/(flavours\s+=).*/\1 generic/" debian.master/rules.d/amd64.mk

echo -e ">>> Args.... exclude is $exclude"
if [ "$exclude" != "none" ]
then
  IFS=',' read -ra pkgs <<< "$exclude"
  for pkg in "${pkgs[@]}"
  do
    if [ "$pkg" == "cloud-tools" ]
    then
      sed -i -re "s/(do_tools_hyperv\s+=).*/\1 false/" debian.master/rules.d/amd64.mk
    elif [ "$pkg" == "tools" ]
    then
      # This doesn't work. We'll rename tools packages instead
      sed -i -re "s/^(do_tools_)((common|host)\s+=).*/\1\2 false/" debian.master/rules.d/amd64.mk
      echo "do_linux_tools  = false" >> debian.master/rules.d/amd64.mk
    elif [ "$pkg" == "udebs" ]
    then
      echo "disable_d_i     = true" >> debian.master/rules.d/amd64.mk
    fi
  done
fi

echo -e ">>> Args.... checkbugs is $checkbugs"
if [ "$checkbugs" == "yes" ]
then
  echo -e "********\n\nChecking for potential bugs\n\n********\n"
  if [ "$(cat debian/debian.env)" == "DEBIAN=debian.master" ]
  then
    echo ">>>  ---> debian.env bug == no"
  else
    echo ">>>  ---> debian.env bug == yes"
    echo "DEBIAN=debian.master" > debian/debian.env
  fi
fi

echo -e "********\n\nApplying default configs\n\n********"
echo 'archs="amd64"' > debian.master/etc/kernelconfig
fakeroot debian/rules clean defaultconfigs
#fakeroot debian/rules importconfigs
fakeroot debian/rules clean

# Build
echo -e "********\n\nBuilding packages\nCommand: dpkg-buildpackage --build=$btype $buildargs\n\n********"
dpkg-buildpackage --build=$btype $buildargs

echo ">>> Building generic metapackage"
do_metapackage "${kver:1}" "${metaver}" "${metatime}" REMOVEME REMOVEME "$maintainer" "$abinum" REMOVEME

echo -e "********\n\nMoving packages to debs folder\n\n********"
[ -d "$kdeb/$kver" ] || mkdir "$kdeb/$kver"
mv "$ksrc"/../*.* "$kdeb/$kver"

if [ "$clean" == "yes" ]
then
  echo -e "********\n\nRemoving git source tree\n\n********"
  rm -r /home/source/*
  rm -r /home/source/.[a-z]*
else
  echo -e "********\n\nCleaning git source tree\n\n********"
  git clean -fdx
  git reset --hard HEAD
fi

