#!/bin/bash
#find-debuginfo.sh - automagically generate debug info and file list
#for inclusion in an rpm spec file.
#
# Usage: find-debuginfo.sh [--strict-build-id] [-g] [-r] [-m] [-i]
#	 		   [-o debugfiles.list]
#			   [--run-dwz] [--dwz-low-mem-die-limit N]
#			   [--dwz-max-die-limit N]
#			   [--ver-rel VERSION-RELEASE]
#			   [[-l filelist]... [-p 'pattern'] -o debuginfo.list]
#			   [builddir]
#
# The -g flag says to use strip -g instead of full strip on DSOs or EXEs.
# The --strict-build-id flag says to exit with failure status if
# any ELF binary processed fails to contain a build-id note.
# The -r flag says to use eu-strip --reloc-debug-sections.
# The -m flag says to include a .gnu_debugdata section in the main binary.
# The -i flag says to include a .gdb_index section in the .debug file.
#
# A single -o switch before any -l or -p switches simply renames
# the primary output file from debugfiles.list to something else.
# A -o switch that follows a -p switch or some -l switches produces
# an additional output file with the debuginfo for the files in
# the -l filelist file, or whose names match the -p pattern.
# The -p argument is an grep -E -style regexp matching the a file name,
# and must not use anchors (^ or $).
#
# The --run-dwz flag instructs find-debuginfo.sh to run the dwz utility
# if available, and --dwz-low-mem-die-limit and --dwz-max-die-limit
# provide detailed limits.  See dwz(1) -l and -L option for details.
#
# If --ver-rel VERSION-RELEASE is given then debugedit is called to
# update the build-ids it finds adding the VERSION-RELEASE string as
# seed to recalculate the build-id hash.  This makes sure the
# build-ids in the ELF files are unique between versions and releases
# of the same package.
#
# All file names in switches are relative to builddir (. if not given).
#

# Figure out where we are installed so we can call other helper scripts.
lib_rpm_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# With -g arg, pass it to strip on libraries or executables.
strip_g=false

# with -r arg, pass --reloc-debug-sections to eu-strip.
strip_r=false

# with -m arg, add minimal debuginfo to binary.
include_minidebug=false

# with -i arg, add GDB index to .debug file.
include_gdb_index=false

# Barf on missing build IDs.
strict=false

# DWZ parameters.
run_dwz=false
dwz_low_mem_die_limit=
dwz_max_die_limit=

# Version and release of the spec. Given by --ver-rel
ver_rel=

# Arch given by --unique-debug-arch
unique_debug_arch=

# Number of parallel jobs to spawn
n_jobs=1

BUILDDIR=.
out=debugfiles.list
nout=0
while [ $# -gt 0 ]; do
  case "$1" in
  --strict-build-id)
    strict=true
    ;;
  --run-dwz)
    run_dwz=true
    ;;
  --dwz-low-mem-die-limit)
    dwz_low_mem_die_limit=$2
    shift
    ;;
  --dwz-max-die-limit)
    dwz_max_die_limit=$2
    shift
    ;;
  --ver-rel)
    ver_rel=$2
    shift
    ;;
  --unique-debug-arch)
    unique_debug_arch=$2
    shift
    ;;
  -g)
    strip_g=true
    ;;
  -m)
    include_minidebug=true
    ;;
  -i)
    include_gdb_index=true
    ;;
  -o)
    if [ -z "${lists[$nout]}" -a -z "${ptns[$nout]}" ]; then
      out=$2
    else
      outs[$nout]=$2
      ((nout++))
    fi
    shift
    ;;
  -l)
    lists[$nout]="${lists[$nout]} $2"
    shift
    ;;
  -p)
    ptns[$nout]=$2
    shift
    ;;
  -r)
    strip_r=true
    ;;
  -j)
    n_jobs=$2
    shift
    ;;
  -j*)
    n_jobs=${1#-j}
    ;;
  *)
    BUILDDIR=$1
    shift
    break
    ;;
  esac
  shift
done

if test -z "$ver_rel" -a -n "$unique_debug_arch"; then
  echo >&2 "*** ERROR: --unique-debug-arch (${unique_debug_arch}) needs --ver-rel (${ver_rel})"
  exit 2
fi

i=0
while ((i < nout)); do
  outs[$i]="$BUILDDIR/${outs[$i]}"
  l=''
  for f in ${lists[$i]}; do
    l="$l $BUILDDIR/$f"
  done
  lists[$i]=$l
  ((++i))
done

LISTFILE="$BUILDDIR/$out"
SOURCEFILE="$BUILDDIR/debugsources.list"
LINKSFILE="$BUILDDIR/debuglinks.list"
ELFBINSFILE="$BUILDDIR/elfbins.list"

> "$SOURCEFILE"
> "$LISTFILE"
> "$LINKSFILE"
> "$ELFBINSFILE"

debugdir="${RPM_BUILD_ROOT}/usr/lib/debug"

strip_to_debug()
{
  local g=
  local r=
  $strip_r && r=--reloc-debug-sections
  $strip_g && case "$(file -bi "$2")" in
  application/x-sharedlib*) g=-g ;;
  application/x-executable*) g=-g ;;
  esac
  eu-strip --remove-comment $r $g -f "$1" "$2" || exit
  chmod 444 "$1" || exit
}

add_minidebug()
{
  local debuginfo="$1"
  local binary="$2"

  local dynsyms=`mktemp`
  local funcsyms=`mktemp`
  local keep_symbols=`mktemp`
  local mini_debuginfo=`mktemp`

  # Extract the dynamic symbols from the main binary, there is no need to also have these
  # in the normal symbol table
  nm -D "$binary" --format=posix --defined-only | awk '{ print $1 }' | sort > "$dynsyms"
  # Extract all the text (i.e. function) symbols from the debuginfo
  nm "$debuginfo" --format=posix --defined-only | awk '{ if ($2 == "T" || $2 == "t") print $1 }' | sort > "$funcsyms"
  # Keep all the function symbols not already in the dynamic symbol table
  comm -13 "$dynsyms" "$funcsyms" > "$keep_symbols"
  # Copy the full debuginfo, keeping only a minumal set of symbols and removing some unnecessary sections
  objcopy -S --remove-section .gdb_index --remove-section .comment --keep-symbols="$keep_symbols" "$debuginfo" "$mini_debuginfo" &> /dev/null
  #Inject the compressed data into the .gnu_debugdata section of the original binary
  xz "$mini_debuginfo"
  mini_debuginfo="${mini_debuginfo}.xz"
  objcopy --add-section .gnu_debugdata="$mini_debuginfo" "$binary"
  rm -f "$dynsyms" "$funcsyms" "$keep_symbols" "$mini_debuginfo"
}

# Make a relative symlink to $1 called $3$2
shopt -s extglob
link_relative()
{
  local t="$1" f="$2" pfx="$3"
  local fn="${f#/}" tn="${t#/}"
  local fd td d

  while fd="${fn%%/*}"; td="${tn%%/*}"; [ "$fd" = "$td" ]; do
    fn="${fn#*/}"
    tn="${tn#*/}"
  done

  d="${fn%/*}"
  if [ "$d" != "$fn" ]; then
    d="${d//+([!\/])/..}"
    tn="${d}/${tn}"
  fi

  mkdir -p "$(dirname "$pfx$f")" && ln -snf "$tn" "$pfx$f"
}

# Make a symlink in /usr/lib/debug/$2 to $1
debug_link()
{
  local l="/usr/lib/debug$2"
  local t="$1"
  echo >> "$LINKSFILE" "$l $t"
  link_relative "$t" "$l" "$RPM_BUILD_ROOT"
}

get_debugfn()
{
  dn=$(dirname "${1#$RPM_BUILD_ROOT}")
  if test -n "${unique_debug_arch}"; then
    bn=$(basename "$1" .debug)-${ver_rel}.${unique_debug_arch}.debug
  else
    bn=$(basename "$1" .debug).debug
  fi

  debugdn=${debugdir}${dn}
  debugfn=${debugdn}/${bn}
}

set -o pipefail

strict_error=ERROR
$strict || strict_error=WARNING

temp=$(mktemp -d ${TMPDIR:-/tmp}/find-debuginfo.XXXXXX)
trap 'rm -rf "$temp"' EXIT

# Build a list of unstripped ELF files and their hardlinks
touch "$temp/primary"
find "$RPM_BUILD_ROOT" ! -path "${debugdir}/*.debug" -type f \
     		     \( -perm -0100 -or -perm -0010 -or -perm -0001 \) \
		     -print |
file -N -f - | sed -n -e 's/^\(.*\):[ 	]*.*ELF.*, not stripped.*/\1/p' |
xargs --no-run-if-empty stat -c '%h %D_%i %n' |
while read nlinks inum f; do
  if [ $nlinks -gt 1 ]; then
    var=seen_$inum
    if test -n "${!var}"; then
      echo "$inum $f" >>"$temp/linked"
      continue
    else
      read "$var" < <(echo 1)
    fi
  fi
  echo "$nlinks $inum $f" >>"$temp/primary"
done

# Strip ELF binaries
do_file()
{
  local nlinks=$1 inum=$2 f=$3 id link linked

  get_debugfn "$f"
  [ -f "${debugfn}" ] && return

  echo "extracting debug info from $f"
  build_id_seed=
  if [ ! -z "$ver_rel" ]; then
    build_id_seed="--build-id-seed=$ver_rel"
  fi
  id=$(${lib_rpm_dir}/debugedit -b "$RPM_BUILD_DIR" -d /usr/src/debug \
			      -i $build_id_seed -l "$SOURCEFILE" "$f") || exit
  if [ -z "$id" ]; then
    echo >&2 "*** ${strict_error}: No build ID note found in $f"
    $strict && exit 2
  fi

  # Add .gdb_index if requested.
  if $include_gdb_index; then
    if type gdb-add-index >/dev/null 2>&1; then
      gdb-add-index "$f"
    else
      echo >&2 "*** ERROR: GDB index requested, but no gdb-add-index installed"
      exit 2
    fi
  fi

  # A binary already copied into /usr/lib/debug doesn't get stripped,
  # just has its file names collected and adjusted.
  case "$dn" in
  /usr/lib/debug/*)
    continue ;;
  esac

  mkdir -p "${debugdn}"
  if test -w "$f"; then
    strip_to_debug "${debugfn}" "$f"
  else
    chmod u+w "$f"
    strip_to_debug "${debugfn}" "$f"
    chmod u-w "$f"
  fi

  # strip -g implies we have full symtab, don't add mini symtab in that case.
  $strip_g || ($include_minidebug && add_minidebug "${debugfn}" "$f")

  echo "./${f#$RPM_BUILD_ROOT}" >> "$ELFBINSFILE"

  # If this file has multiple links, make the corresponding .debug files
  # all links to one file too.
  if [ $nlinks -gt 1 ]; then
    grep "^$inum " "$temp/linked" | while read inum linked; do
      link=$debugfn
      get_debugfn "$linked"
      echo "hard linked $link to $debugfn"
      mkdir -p "$(dirname "$debugfn")" && ln -nf "$link" "$debugfn"
    done
  fi
}

# 16^6 - 1 or about 16 milion files
FILENUM_DIGITS=6
run_job()
{
  local jobid=$1 filenum
  local SOURCEFILE=$temp/debugsources.$jobid ELFBINSFILE=$temp/elfbins.$jobid

  >"$SOURCEFILE"
  >"$ELFBINSFILE"
  # can't use read -n <n>, because it reads bytes one by one, allowing for
  # races
  while :; do
    filenum=$(dd bs=$(( FILENUM_DIGITS + 1 )) count=1 status=none)
    if test -z "$filenum"; then
      break
    fi
    do_file $(sed -n "$(( 0x$filenum )) p" "$temp/primary")
  done
  echo 0 >"$temp/res.$jobid"
}

n_files=$(wc -l <"$temp/primary")
if [ $n_jobs -gt $n_files ]; then
  n_jobs=$n_files
fi
if [ $n_jobs -le 1 ]; then
  while read nlinks inum f; do
    do_file "$nlinks" "$inum" "$f"
  done <"$temp/primary"
else
  for ((i = 1; i <= n_files; i++)); do
    printf "%0${FILENUM_DIGITS}x\\n" $i
  done | (
    exec 3<&0
    for ((i = 0; i < n_jobs; i++)); do
      # The shell redirects stdin to /dev/null for background jobs. Work
      # around this by duplicating fd 0
      run_job $i <&3 &
    done
    wait
  )
  for f in "$temp"/res.*; do
    res=$(< "$f")
    if [ "$res" !=  "0" ]; then
      exit 1
    fi
  done
  cat "$temp"/debugsources.* >"$SOURCEFILE"
  cat "$temp"/elfbins.* >"$ELFBINSFILE"
fi

# Invoke the DWARF Compressor utility.
if $run_dwz \
   && [ -d "${RPM_BUILD_ROOT}/usr/lib/debug" ]; then
  dwz_files="`cd "${RPM_BUILD_ROOT}/usr/lib/debug"; find -type f -name \*.debug`"
  if [ -n "${dwz_files}" ]; then
    dwz_multifile_name="${RPM_PACKAGE_NAME}-${RPM_PACKAGE_VERSION}-${RPM_PACKAGE_RELEASE}.${RPM_ARCH}"
    dwz_multifile_suffix=
    dwz_multifile_idx=0
    while [ -f "${RPM_BUILD_ROOT}/usr/lib/debug/.dwz/${dwz_multifile_name}${dwz_multifile_suffix}" ]; do
      let ++dwz_multifile_idx
      dwz_multifile_suffix=".${dwz_multifile_idx}"
    done
    dwz_multfile_name="${dwz_multifile_name}${dwz_multifile_suffix}"
    dwz_opts="-h -q -r -m .dwz/${dwz_multifile_name}"
    mkdir -p "${RPM_BUILD_ROOT}/usr/lib/debug/.dwz"
    [ -n "${dwz_low_mem_die_limit}" ] \
      && dwz_opts="${dwz_opts} -l ${dwz_low_mem_die_limit}"
    [ -n "${dwz_max_die_limit}" ] \
      && dwz_opts="${dwz_opts} -L ${dwz_max_die_limit}"
    if type dwz >/dev/null 2>&1; then
      ( cd "${RPM_BUILD_ROOT}/usr/lib/debug" && dwz $dwz_opts $dwz_files )
    else
      echo >&2 "*** ERROR: DWARF compression requested, but no dwz installed"
      exit 2
    fi
    # Remove .dwz directory if empty
    rmdir "${RPM_BUILD_ROOT}/usr/lib/debug/.dwz" 2>/dev/null
    if [ -f "${RPM_BUILD_ROOT}/usr/lib/debug/.dwz/${dwz_multifile_name}" ]; then
      id="`readelf -Wn "${RPM_BUILD_ROOT}/usr/lib/debug/.dwz/${dwz_multifile_name}" \
	     2>/dev/null | sed -n 's/^    Build ID: \([0-9a-f]\+\)/\1/p'`"
    fi

    # dwz invalidates .gnu_debuglink CRC32 in the main files.
    cat "$ELFBINSFILE" |
    (cd "$RPM_BUILD_ROOT"; \
     xargs -d '\n' ${lib_rpm_dir}/sepdebugcrcfix usr/lib/debug)
  fi
fi

# For each symlink whose target has a .debug file,
# make a .debug symlink to that file.
find "$RPM_BUILD_ROOT" ! -path "${debugdir}/*" -type l -print |
while read f
do
  t=$(readlink -m "$f").debug
  f=${f#$RPM_BUILD_ROOT}
  t=${t#$RPM_BUILD_ROOT}
  if [ -f "$debugdir$t" ]; then
    echo "symlinked /usr/lib/debug$t to /usr/lib/debug${f}.debug"
    debug_link "/usr/lib/debug$t" "${f}.debug"
  fi
done

if [ -s "$SOURCEFILE" ]; then
  mkdir -p "${RPM_BUILD_ROOT}/usr/src/debug"
  LC_ALL=C sort -z -u "$SOURCEFILE" | grep -E -v -z '(<internal>|<built-in>)$' |
  (cd "$RPM_BUILD_DIR"; cpio -pd0mL "${RPM_BUILD_ROOT}/usr/src/debug")
  # stupid cpio creates new directories in mode 0700, fixup
  find "${RPM_BUILD_ROOT}/usr/src/debug" -type d -print0 |
  xargs --no-run-if-empty -0 chmod a+rx
fi

if [ -d "${RPM_BUILD_ROOT}/usr/lib" -o -d "${RPM_BUILD_ROOT}/usr/src" ]; then
  ((nout > 0)) ||
  test ! -d "${RPM_BUILD_ROOT}/usr/lib" ||
  (cd "${RPM_BUILD_ROOT}/usr/lib"; find debug -type d) |
  sed 's,^,%dir /usr/lib/,' >> "$LISTFILE"

  (cd "${RPM_BUILD_ROOT}/usr"
   test ! -d lib/debug || find lib/debug ! -type d
   test ! -d src/debug || find src/debug -mindepth 1 -maxdepth 1
  ) | sed 's,^,/usr/,' >> "$LISTFILE"
fi

# Append to $1 only the lines from stdin not already in the file.
append_uniq()
{
  grep -F -f "$1" -x -v >> "$1"
}

# Helper to generate list of corresponding .debug files from a file list.
filelist_debugfiles()
{
  local extra="$1"
  shift
  sed 's/^%[a-z0-9_][a-z0-9_]*([^)]*) *//
s/^%[a-z0-9_][a-z0-9_]* *//
/^$/d
'"$extra" "$@"
}

# Write an output debuginfo file list based on given input file lists.
filtered_list()
{
  local out="$1"
  shift
  test $# -gt 0 || return
  grep -F -f <(filelist_debugfiles 's,^.*$,/usr/lib/debug&.debug,' "$@") \
  	-x $LISTFILE >> $out
  sed -n -f <(filelist_debugfiles 's/[\\.*+#]/\\&/g
h
s,^.*$,s# &$##p,p
g
s,^.*$,s# /usr/lib/debug&.debug$##p,p
' "$@") "$LINKSFILE" | append_uniq "$out"
}

# Write an output debuginfo file list based on an grep -E -style regexp.
pattern_list()
{
  local out="$1" ptn="$2"
  test -n "$ptn" || return
  grep -E -x -e "$ptn" "$LISTFILE" >> "$out"
  sed -n -r "\#^$ptn #s/ .*\$//p" "$LINKSFILE" | append_uniq "$out"
}

#
# When given multiple -o switches, split up the output as directed.
#
i=0
while ((i < nout)); do
  > ${outs[$i]}
  filtered_list ${outs[$i]} ${lists[$i]}
  pattern_list ${outs[$i]} "${ptns[$i]}"
  grep -Fvx -f ${outs[$i]} "$LISTFILE" > "${LISTFILE}.new"
  mv "${LISTFILE}.new" "$LISTFILE"
  ((++i))
done
if ((nout > 0)); then
  # Now add the right %dir lines to each output list.
  (cd "${RPM_BUILD_ROOT}"; find usr/lib/debug -type d) |
  sed 's#^.*$#\\@^/&/@{h;s@^.*$@%dir /&@p;g;}#' |
  LC_ALL=C sort -ur > "${LISTFILE}.dirs.sed"
  i=0
  while ((i < nout)); do
    sed -n -f "${LISTFILE}.dirs.sed" "${outs[$i]}" | sort -u > "${outs[$i]}.new"
    cat "${outs[$i]}" >> "${outs[$i]}.new"
    mv -f "${outs[$i]}.new" "${outs[$i]}"
    ((++i))
  done
  sed -n -f "${LISTFILE}.dirs.sed" "${LISTFILE}" | sort -u > "${LISTFILE}.new"
  cat "$LISTFILE" >> "${LISTFILE}.new"
  mv "${LISTFILE}.new" "$LISTFILE"
fi
