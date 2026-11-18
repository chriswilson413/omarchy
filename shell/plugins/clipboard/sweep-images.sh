#!/bin/bash

# Deletes clipboard images that the clipboard history no longer lists.
#
# The history file on disk decides: an image goes only when that file reads as a
# clipboard history and doesn't list it. A history that is missing or doesn't
# read as a single JSON array keeps every image.
#
# Given images (the ones the shell just dropped), only those are candidates, and
# the ones kept are printed so the shell can offer them again after its next
# save. Without any, every image capture.sh could have written is: the
# <sha256>[.XXXXXX].<ext> files and the clipboard.XXXXXX leftovers of an
# interrupted capture, except those from the last minute, which a capture may
# not have listed yet. Either way only files directly inside images-dir go.

if (( $# < 2 )); then
  echo "Usage: sweep-images.sh <images-dir> <history-file> [image...]" >&2
  exit 1
fi

images_dir="${1%/}"
history_path="$2"
shift 2
given=("$@")
managed='^([0-9a-f]{64}(\.[A-Za-z0-9]{6})?\.[A-Za-z0-9+-]+|clipboard\.[A-Za-z0-9]{6})$'

[[ -d $images_dir ]] || exit 0

# Candidates come before the history is read, so an image listed in between is kept.
candidates=()
if (( ${#given[@]} > 0 )); then
  for image in "${given[@]}"; do
    if [[ ${image%/*} == "$images_dir" && ${image##*/} =~ $managed && -f $image && ! -L $image ]]; then
      candidates+=("$image")
    fi
  done
else
  while IFS= read -r -d '' image; do
    if [[ ${image##*/} =~ $managed ]]; then
      candidates+=("$image")
    fi
  done < <(find "$images_dir/" -maxdepth 1 -type f ! -newermt "1 minute ago" -print0)
fi

(( ${#candidates[@]} > 0 )) || exit 0

keep_all() {
  if (( ${#given[@]} > 0 )); then
    printf '%s\n' "${candidates[@]}"
  fi
  exit 0
}

[[ -e $history_path ]] || keep_all

# Read like the shell's ClipboardHistory.normalizeEntry, which takes
# String(value.type || value.kind) and String(value.path): an empty or zero type
# falls back to the kind, and arrays read as their joined items. Slurped, so an
# empty file or a second document fails like a malformed one, and so does a NaN
# or Infinity, which jq accepts and the shell's JSON.parse rejects.
referenced=$(jq -rs '
  def present: . != null and . != false and . != 0 and . != "";
  def jsstr: if type == "array" then map(if . == null then "" else jsstr end) | join(",")
    elif type == "object" then "[object Object]"
    else tostring end;
  if length == 1 and (.[0] | type) == "array"
    and ([.[0] | .. | numbers | select(isnan or isinfinite)] | length) == 0 then
    .[0][] | objects
      | select((if (.type | present) then .type else .kind end | jsstr) == "image")
      | .path | select(present) | jsstr
  else
    error("not a clipboard history")
  end' "$history_path" 2>/dev/null) || keep_all

declare -A listed=()
while IFS= read -r path; do
  if [[ -n $path ]]; then
    listed["${path##*/}"]=1
  fi
done <<<"$referenced"

doomed=()
for image in "${candidates[@]}"; do
  if [[ -n ${listed["${image##*/}"]:-} ]]; then
    if (( ${#given[@]} > 0 )); then
      printf '%s\n' "$image"
    fi
  else
    doomed+=("$image")
  fi
done

# In batches, since a first sweep may find a long backlog.
if (( ${#doomed[@]} > 0 )); then
  printf '%s\0' "${doomed[@]}" | xargs -0 rm -f --
fi
