#!/bin/bash
# Fails when glslang, SPIRV-Cross and our shim define the same non-std symbol.
#
#   ./Scripts/check-toolchain-symbols.sh <derived data path>
#
# The linker rejects duplicate strong symbols but silently keeps one of two weak (inline or
# template) definitions. Both libraries declare `spv::`, so a shared inline name with different
# bodies would compile one library against the other's code. SPIRV-Cross's copy lives in
# `spvc_spv` (Vendor/ShaderToolchain/Package.swift); this keeps it that way. Allowed: instantiations
# of the C++ standard library, coverage records, and the libraries' own inline code in the shim,
# which includes their headers.

set -euo pipefail

DERIVED="${1:?usage: $0 <derived data path>}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for target in glslang SPIRVCross ShaderToolchain; do
    # Xcode names a package target's build directory `<target>-t.build` or `<target>.build`.
    objects=$(find "$DERIVED" -name "*.o" \( -path "*/$target-t.build/Objects-normal/*" \
        -o -path "*/$target.build/Objects-normal/*" \))
    if [[ -z "$objects" ]]; then
        echo "error: no object files for $target under $DERIVED" >&2
        exit 1
    fi
    while read -r object; do
        nm -gU "$object" 2>/dev/null || true
    done <<< "$objects" | awk 'NF >= 3 { print $3 }' | sort -u > "$WORK/$target"
done

status=0
for pair in glslang:SPIRVCross glslang:ShaderToolchain SPIRVCross:ShaderToolchain; do
    a=${pair%%:*}
    b=${pair##*:}
    clashes=$(comm -12 "$WORK/$a" "$WORK/$b" | c++filt \
        | grep -Ev '^([a-z]+( [a-z]+)*[&*]* )?std::|^(typeinfo|vtable|guard variable) for std::' \
        | grep -Ev '^___clang_call_terminate$|^___covrec_|^___llvm_profile_|^___profc_|^___profd_' \
        | { [[ "$b" == ShaderToolchain ]] \
              && grep -Ev '^((typeinfo|typeinfo name|vtable) for )?(spv|glslang|spirv_cross)::' || cat; } || true)
    if [[ -n "$clashes" ]]; then
        echo "error: symbols defined by both $a and $b:" >&2
        echo "$clashes" | head -n 20 >&2
        status=1
    fi
done
[[ $status -eq 0 ]] && echo "shader toolchain symbols: no clashes"
exit $status
