# Warning: Do not execute. Instead, include it from a package specific scriptlet

# Auto install packages after installation. Useful for bootstrap
# export PKG_AUTO_INSTALL=1

# Default location where package sources are stored
export SROOT=/media/ntfs/Other/Linux/sources

# Default location where patches are stored
export PROOT=/media/ntfs/Other/Linux/patches

# Default C compiler used to build 64 bit packages
if [ -z "${DEFAULT_CC}" ]
then
  export DEFAULT_CC="clang"
fi

# Default C++ compiler used to build 64 bit packages
if [ -z "${DEFAULT_CXX}" ]
then
  export DEFAULT_CXX="clang++ -stdlib=libc++"
fi

# Default C compiler used to build 32 bit packages
if [ -z "${DEFAULT_CC_M32}" ]
then
  export DEFAULT_CC_M32="clang -m32"
fi

# Default C++ compiler used to build 32 bit packages
if [ -z "${DEFAULT_CXX_M32}" ]
then
  export DEFAULT_CXX_M32="clang++ -m32 -stdlib=libc++"
fi

# -march=skylake -mno-avx512f works with clang, but not gcc - grrrr
export DEFAULT_CFLAGS="-march=broadwell -fomit-frame-pointer -Ofast -pipe -fstack-protector-strong"
export DEFAULT_CXXFLAGS="-march=broadwell -fomit-frame-pointer -Ofast -pipe -fstack-protector-strong"

export DEFAULT_DEBUG_CFLAGS="-march=broadwell -g -Ofast -pipe -fstack-protector-strong"
export DEFAULT_DEBUG_CXXFLAGS="-march=broadwell -g -Ofast -pipe -fstack-protector-strong"

if [ -z ${PKGNAME} ] || [ -z ${PKGVER} ]
then
  echo "Missing either PKGNAME or PKGVER variables for your package."
  exit 1
fi

if [ -z ${PKGTAR} ]
then
  export PKGTAR=${PKGNAME}-${PKGVER}.tar.xz
fi

if [ -z ${PKGDIR} ]
then
  export PKGDIR=${PKGNAME}-${PKGVER}
fi

if [ -z ${PKGBUILD} ]
then
  if [ -z ${CMAKE_BUILD} ]
  then
    export PKGBUILD=${PKGDIR}
  else
    export PKGBUILD=${PKGNAME}-build
    export PATH_TO_SOURCE="../${PKGDIR}"
  fi
fi

if [ -z ${DEST} ]
then
  export DEST=/binary/${PKGNAME}-${PKGVER}
fi

function_exists() {
    declare -f -F $1 > /dev/null
    return $?
}

prepare_src() {
  if [ -z $1 ]
  then
    echo "Function requires a parameter: prepare_src tarball.tar.gz"
    exit 1
  fi

  local PKGTAR=$1

  if [ ! -e ${SROOT}/${PKGTAR} ]
  then
    if [ -z ${PKGURL} ]
    then
      echo "Tarball not locally available and URL not given. Giving up."
      exit 1
    fi

    wget -c ${PKGURL} -O ${SROOT}/${PKGTAR} || exit ${PIPESTATUS}
  fi

  if [ -e ${PKGDIR} ] || [ -e ${PKGBUILD} ]
  then
    if [ -z ${RECURSIVE_CALL} ]
    then
      echo "Warning: Old source and/or build dir exists. Removing."
      rm -rf ${PKGDIR} ${PKGBUILD}
    fi
  fi

  if [ -e ${DEST} ] || [ -e ${DEST}-debug ]
  then
    if [ ${PKG_BUILDING} != 1 ]
    then
      echo "Warning: Old package installation dir exits. Removing."
      rm -rf ${DEST} ${DEST}-debug
    fi
  fi

  export PKG_BUILDING=1

  bsdtar xf ${SROOT}/${PKGTAR}

  if [ ! -z ${CMAKE_BUILD} ]
  then
    if [ "${PKGDIR}" != "${PKGBUILD}" ]
    then
      install -dm755 ${PKGBUILD}
    fi
  fi

  function_exists post_extract_action && post_extract_action || true
}

patch_apply() {
  if [ -z $1 ]
  then
    echo "Function requires a parameter: patch_apply patchname"
    exit 1
  fi

  local PATCH=$1

  if [ "$(basename ${PATCH})" == "${PATCH}" ]
  then
    PNAME=${PROOT}/${PATCH}
  else
    PNAME=${PATCH}
  fi

  pushd ${PKGDIR}
    patch -Np1 -i ${PNAME}
  popd
}

remove_rpath() {
  pushd ${DEST}

    find * -type f 2>/dev/null | while read BUILD_BINARY ; do
      case "$(file -bi "${BUILD_BINARY}")" in *application/x-sharedlib* | *application/x-executable*)
        chrpath -d ${BUILD_BINARY}
      esac
    done

  popd
}

pkg_strip() {
  pushd ${DEST}

    find * -type f 2>/dev/null | while read BUILD_BINARY ; do
      case "$(file -bi "${BUILD_BINARY}")" in *application/x-sharedlib* | *application/x-executable*)
        strip --strip-unneeded ${BUILD_BINARY}
      esac
    done

    find * -name "*.a" -exec strip --strip-unneeded {} \;
  popd
}

make_separate_debug_info() {
  pushd ${DEST}

    find * -type f 2>/dev/null | while read BUILD_BINARY ; do
      case "$(file -bi "${BUILD_BINARY}")" in *application/x-sharedlib* | *application/x-executable*)
        mkdir -p usr/lib/debug/$(dirname ${BUILD_BINARY})
        objcopy --only-keep-debug ${BUILD_BINARY} usr/lib/debug/${BUILD_BINARY}
        strip --strip-unneeded ${BUILD_BINARY}
        objcopy --add-gnu-debuglink=usr/lib/debug/${BUILD_BINARY} ${BUILD_BINARY}
      esac
    done

    if [ -e usr/lib/debug ]
    then
      install -dm755 ${DEST}-debug/usr/lib
      mv usr/lib/debug ${DEST}-debug/usr/lib
    fi
  popd
}

post_install_clean() {
  if [ -z ${KEEP_LA} ]
  then
    find ${DEST} -name "*.la" -delete
  fi

  find ${DEST} -name "*.so" -exec chmod 755 {} \;
  find ${DEST} \( -name .packlist -o -name perllocal.pod \) -delete

  rm -rf ${DEST}/usr/share/info/dir

  if [ -z ${NO_COMPRESS_INFO} ] && [ -e ${DEST}/usr/share/info ]
  then
    gzip -9 ${DEST}/usr/share/info/*
  fi

  if [ -z ${KEEP_LOCALIZED_MAN} ]
  then
    rm -rf ${DEST}/usr/share/man/[^man{1..8,n}]*
  fi

  if [ -z ${KEEP_DOC} ]
  then
    rm -rf ${DEST}/usr/share/doc
    rm -rf ${DEST}/usr/doc*
  fi

  if [ -z ${KEEP_EMPTY_DIRS} ]
  then
    find ${DEST} -type d -empty -delete
  fi

  if [ ! -z ${DEBUG_BUILD} ]
  then
    make_separate_debug_info
  elif [ -z ${NO_STRIP} ]
  then
    pkg_strip
  fi
}

generate_install() {
  printf "#!/bin/bash" > ${DEST}/INSTALL
  printf "\n\n" >> ${DEST}/INSTALL

  if [ -z "${INSTALL_CMD}" ]
  then
    local DIRS=$(find ${DEST} -maxdepth 1 ! -path ${DEST} -type d -exec basename {} \; | sort | xargs)
    local NUM=$(find ${DEST} -maxdepth 1 ! -path ${DEST} -type d -exec basename {} \; | wc -l)

    if [ ${NUM} == 1 ]
    then
      local INSTALL_CMD="cp -rf --remove-destination ${DIRS} /"
    else
      local INSTALL_CMD="for dir in ${DIRS} ; do cp -rf --remove-destination \$dir / ; done"
    fi
    printf "${INSTALL_CMD}\n" >> ${DEST}/INSTALL
  else
    local LEN=${#INSTALL_CMD[@]}

    for (( i=0; i < ${LEN}; i++ ));
    do
      printf "${INSTALL_CMD[$i]}\n" >> ${DEST}/INSTALL
    done

    unset LEN
  fi

  if [ ! -z "${POSTINST_TRIGGER}" ]
  then
    printf "\n" >> ${DEST}/INSTALL
    local LEN=${#POSTINST_TRIGGER[@]}

    for (( i=0; i < ${LEN}; i++ ));
    do
      printf "${POSTINST_TRIGGER[$i]}\n" >> ${DEST}/INSTALL
    done
  fi

  if [ -z ${SPACE_ADDED} ]
  then
     local SPACE_ADDED=0
  fi

  if [ -e ${DEST}/usr/share/glib-2.0/schemas ]
  then

    if [ ${SPACE_ADDED} != 1 ]
    then
      printf "\n" >> ${DEST}/INSTALL
      SPACE_ADDED=1
    fi

printf '[ -x /usr/bin/glib-compile-schemas ] && echo "Processing triggers for glib-2.0" && /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas\n' >> ${DEST}/INSTALL

  fi

  if [ -e ${DEST}/usr/share/mime ]
  then

    if [ ${SPACE_ADDED} != 1 ]
    then
      printf "\n" >> ${DEST}/INSTALL
      SPACE_ADDED=1
    fi

printf '[ -x /usr/bin/update-mime-database ] && echo "Processing triggers for shared-mime-info" && /usr/bin/update-mime-database /usr/share/mime\n' >> ${DEST}/INSTALL

  fi

  if [ -e ${DEST}/usr/share/icons/hicolor ]
  then

    if [ ${SPACE_ADDED} != 1 ]
    then
      printf "\n" >> ${DEST}/INSTALL
      SPACE_ADDED=1
    fi

printf '[ -x /usr/bin/gtk-update-icon-cache ] && echo "Processing triggers for hicolor-icon-theme" && /usr/bin/gtk-update-icon-cache -qf /usr/share/icons/hicolor\n' >> ${DEST}/INSTALL

  fi

  if [ -e ${DEST}/usr/share/applications ]
  then

    if [ ${SPACE_ADDED} != 1 ]
    then
      printf "\n" >> ${DEST}/INSTALL
      SPACE_ADDED=1
    fi

printf '[ -x /usr/bin/update-desktop-database ] && echo "Processing triggers for desktop-file-utils" && /usr/bin/update-desktop-database\n' >> ${DEST}/INSTALL

  fi

  if [ -e ${DEST}/usr/share/info ]
  then

    if [ ${SPACE_ADDED} != 1 ]
    then
      printf "\n" >> ${DEST}/INSTALL
      SPACE_ADDED=1
    fi

printf '[ -x /usr/bin/install-info ] && echo "Processing triggers for texinfo" && for file in usr/share/info/* ; do test -e /$file && /usr/bin/install-info /$file /usr/share/info/dir ; done\n' >> ${DEST}/INSTALL

  fi

  if [ -e ${DEST}/usr/share/man ]
  then

    if [ ${SPACE_ADDED} != 1 ]
    then
      printf "\n" >> ${DEST}/INSTALL
      SPACE_ADDED=1
    fi

printf '[ -x /usr/bin/mandb ] && echo "Processing triggers for man-db" && /usr/bin/mandb -q\n' >> ${DEST}/INSTALL

  fi

  local solib=0
  local sonum=0

  if [ -d ${DEST}/usr/lib ]
  then
    sonum=$(find ${DEST}/usr/lib -maxdepth 1 -name "*.so" | wc -l)
  fi

  if [ ${sonum} -gt "0" ]
  then
    solib=1
  fi

  if  [ ${solib} == "1" ]
  then

    if [ ${SPACE_ADDED} != 1 ]
    then
      printf "\n" >> ${DEST}/INSTALL
      SPACE_ADDED=1
    fi

printf '[ -x /sbin/ldconfig ] && echo "Processing triggers for glibc" && /sbin/ldconfig\n' >> ${DEST}/INSTALL

  fi

  if [ ! -z ${PKG_AUTO_INSTALL} ]
  then
    printf "\nexit 0\n" >> ${DEST}/INSTALL
  fi

  chmod 755 ${DEST}/INSTALL
}

build_package() {

  if [ -z ${PATH_TO_SOURCE} ]
  then
    local PATH_TO_SOURCE="."
  fi

  if [ -z ${NO_OPTIMIZATION} ]
  then

    if [ -z ${CFLAGS} ]
    then
      if [ -z ${DEBUG_BUILD} ]
      then
        export CFLAGS="${DEFAULT_CFLAGS} ${USER_CFLAGS}"
      else
        export CFLAGS="${DEFAULT_DEBUG_CFLAGS} ${USER_CFLAGS}"
      fi
    fi

    if [ -z ${CXXFLAGS} ]
    then
      if [ -z ${DEBUG_BUILD} ]
      then
        export CXXFLAGS="${DEFAULT_CXXFLAGS} ${USER_CXXFLAGS}"
      else
        export CXXFLAGS="${DEFAULT_DEBUG_CXXFLAGS} ${USER_CXXFLAGS}"
      fi
    fi

  fi

  pushd ${PKGBUILD}

    declare -a ADDITIONAL_CONFIGURE_FLAGS

    if [ -z ${KEEP_STATIC} ]
    then
       ADDITIONAL_CONFIGURE_FLAGS=(--disable-static "${ADDITIONAL_CONFIGURE_FLAGS[@]}")
    fi

    if [ ${MULTILIB} == 0 ]
    then
      export CC=${DEFAULT_CC}
      export CXX=${DEFAULT_CXX}
      export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig

      if [ -z ${DEBUG_BUILD} ]
      then
        local ADDITIONAL_CMAKE_FLAGS=(-DCMAKE_BUILD_TYPE=Release "${CMAKE_FLAGS[@]}")
      else
        local ADDITIONAL_CMAKE_FLAGS=(-DCMAKE_BUILD_TYPE=RelWithDebInfo "${CMAKE_FLAGS[@]}")
      fi
      ADDITIONAL_CONFIGURE_FLAGS=("${ADDITIONAL_CONFIGURE_FLAGS[@]}" --libdir=/usr/lib "${CONFIGURE_FLAGS[@]}")
      local ADDITIONAL_MAKE_FLAGS="${MAKE_FLAGS} ${MAKE_JOBS_FLAGS}"
      local ADDITIONAL_MAKE_INSTALL_FLAGS="${MAKE_INSTALL_FLAGS} DESTDIR=${DEST}"
    else
      export CC=${DEFAULT_CC_M32}
      export CXX=${DEFAULT_CXX_M32}
      export PKG_CONFIG_PATH=/usr/lib32/pkgconfig:/usr/share/pkgconfig
      if [ -z ${DEBUG_BUILD} ]
      then
        local ADDITIONAL_CMAKE_FLAGS=(-DCMAKE_BUILD_TYPE=Release "${CMAKE_FLAGS_32[@]}")
      else
        local ADDITIONAL_CMAKE_FLAGS=(-DCMAKE_BUILD_TYPE=RelWithDebInfo "${CMAKE_FLAGS_32}")
      fi
      ADDITIONAL_CONFIGURE_FLAGS+=("${ADDITIONAL_CONFIGURE_FLAGS[@]}" --libdir=/usr/lib32 "${CONFIGURE_FLAGS_32[@]}")
      local ADDITIONAL_MAKE_FLAGS="${MAKE_FLAGS_32} ${MAKE_JOBS_FLAGS}"
      local ADDITIONAL_MAKE_INSTALL_FLAGS="${MAKE_INSTALL_FLAGS_32} DESTDIR=${PWD}/dest"
    fi

    if [ ${MULTILIB} == 0 ]
    then
      function_exists configure_pre && configure_pre
    else
      function_exists configure_pre_32 && configure_pre_32
    fi

    if [ ${MULTILIB} == 0 ] && [ "$(function_exists configure_override; echo $?)" == "0" ]
    then
      configure_override
    elif [ ${MULTILIB} == 1 ] && [ "$(function_exists configure_override_32; echo $?)" == "0" ]
    then
      configure_override_32
    else
      if [ ! -z ${CMAKE_BUILD} ]
      then
        cmake -DCMAKE_INSTALL_PREFIX=/usr     \
              -DCMAKE_C_FLAGS="${CFLAGS}"     \
              -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
              "${ADDITIONAL_CMAKE_FLAGS[@]}"  \
              -Wno-dev ${PATH_TO_SOURCE}
      else
        ${PATH_TO_SOURCE}/configure --prefix=/usr             \
                                    --sysconfdir=/etc         \
                                    --localstatedir=/var      \
                                    --mandir=/usr/share/man   \
                                    --infodir=/usr/share/info \
                                    "${ADDITIONAL_CONFIGURE_FLAGS[@]}"
      fi
    fi

    if [ ${MULTILIB} == 0 ]
    then
      function_exists configure_post && configure_post
    else
      function_exists configure_post_32 && configure_post_32
    fi

    function_exists make_override && make_override || make ${ADDITIONAL_MAKE_FLAGS}

    if [ ${MULTILIB} == 0 ]
    then
      function_exists make_post && make_post
    else
      function_exists make_post_32 && make_post_32
    fi

    function_exists make_install_override && make_install_override || make install ${ADDITIONAL_MAKE_INSTALL_FLAGS}

    if [ ${MULTILIB} == 1 ]
    then
      for d in lib32 usr/lib32
      do
        if [ -d "${PWD}/dest/${d}" ]
        then
          mv ${PWD}/dest/${d} ${DEST}/${d}
        fi
      done
    fi

    if [ ${MULTILIB} == 0 ]
    then
      function_exists make_install_post && make_install_post
    else
      function_exists make_install_post_32 && make_install_post_32
    fi

  popd

  if [ -z ${KEEP_SRC} ] || [ ! -z ${MULTILIB_BUILD} ]
  then
    rm -rf ${PKGDIR} ${PKGBUILD}
  fi

  unset CC CFLAGS CXX CXXFLAGS PKG_CONFIG_PATH
}

export PKG_BUILDING=0
export MULTILIB=0

if [ "$(function_exists prepare_src_override; echo $?)" == "0" ]
then
  prepare_src_override ${PKGTAR}
else
  prepare_src ${PKGTAR}
fi

if [ ! -z ${PATCHES_LIST} ]
then
  LEN=${#PATCHES_LIST[@]}

  for (( i=0; i < ${LEN}; i++ ));
  do
    patch_apply ${PATCHES_LIST[$i]}
  done

  unset LEN i
fi

function_exists build_package_override && build_package_override || build_package

if [ ! -z ${MULTILIB_BUILD} ]
then

  export MULTILIB=1

  function_exists prepare_src_override && prepare_src_override ${PKGTAR} || prepare_src ${PKGTAR}

  if [ ! -z ${PATCHES_LIST_32} ]
  then
    LEN=${#PATCHES_LIST_32[@]}

    for (( i=0; i < ${LEN}; i++ ));
    do
      patch_apply ${PATCHES_LIST_32[$i]}
    done

    unset LEN i
  fi

  function_exists build_package_32_override && build_package_32_override || build_package
fi

function_exists post_install_clean_override && post_install_clean_override || post_install_clean
function_exists post_install_config && post_install_config || true
function_exists generate_install_override && generate_install_override || generate_install

if [ ! -z ${PKG_AUTO_INSTALL} ]
then
  pushd ${DEST}
    ./INSTALL
  popd
fi

if [ ! -z ${PKG_AUTO_INSTALL_DEBUG} ] && [ -e ${DEST}-debug ]
then
  pushd ${DEST}-debug
    cp -a * /
  popd
fi

unset PKG_BUILDING
