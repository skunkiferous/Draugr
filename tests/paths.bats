#!/usr/bin/env bats
# Path translation. One repository has three names. A mix-up of them causes the
# most bugs in this tool, so the table is complete on purpose.

load helper

setup()    { dr_test_setup; dr_load_common; }
teardown() { dr_test_teardown; }

@test "dr_path_win: basic drive path" {
    run dr_path_win /mnt/c/Code/myproject
    [ "$status" -eq 0 ]
    [ "$output" = 'C:\Code\myproject' ]
}

@test "dr_path_win: uppercases the drive letter" {
    run dr_path_win /mnt/d/Data
    [ "$output" = 'D:\Data' ]
}

@test "dr_path_win: drive root" {
    run dr_path_win /mnt/c
    [ "$output" = 'C:\' ]
}

@test "dr_path_win: path containing spaces" {
    run dr_path_win "/mnt/c/Program Files/Git"
    [ "$output" = 'C:\Program Files\Git' ]
}

@test "dr_path_win: deep path" {
    run dr_path_win /mnt/c/a/b/c/d/e
    [ "$output" = 'C:\a\b\c\d\e' ]
}

@test "dr_path_win: rejects a non-drive path" {
    run dr_path_win /home/user/code
    [ "$status" -ne 0 ]
}

@test "dr_path_win: rejects a lookalike prefix" {
    run dr_path_win /mnt/wsl/something
    [ "$status" -ne 0 ]
}

@test "dr_path_mound: strips /mnt" {
    run dr_path_mound /mnt/c/Code/myproject
    [ "$status" -eq 0 ]
    [ "$output" = /c/Code/myproject ]
}

@test "dr_path_mound: drive root" {
    run dr_path_mound /mnt/c
    [ "$output" = /c ]
}

@test "dr_path_mound: rejects a non-drive path" {
    run dr_path_mound /home/user/code
    [ "$status" -ne 0 ]
}

@test "dr_path_from_win: backslash form" {
    run dr_path_from_win 'C:\Users\seb\AppData'
    [ "$status" -eq 0 ]
    [ "$output" = /mnt/c/Users/seb/AppData ]
}

@test "dr_path_from_win: forward-slash form" {
    run dr_path_from_win 'C:/Users/seb'
    [ "$output" = /mnt/c/Users/seb ]
}

@test "dr_path_from_win: lowercases the drive letter" {
    run dr_path_from_win 'D:\Data'
    [ "$output" = /mnt/d/Data ]
}

@test "dr_path_from_win: rejects a unix path" {
    run dr_path_from_win /home/user
    [ "$status" -ne 0 ]
}

@test "round trip: wsl -> win -> wsl" {
    local original=/mnt/c/Code/my.project-2
    run dr_path_from_win "$(dr_path_win "$original")"
    [ "$output" = "$original" ]
}

@test "dr_sandbox_name: derives draugr-<leaf>" {
    run dr_sandbox_name /mnt/c/Code/myproject
    [ "$output" = draugr-myproject ]
}

@test "dr_sandbox_name: strips characters sbx rejects" {
    run dr_sandbox_name "/mnt/c/Code/my project (old)"
    # only lower-case letters, numbers, hyphens and periods. No doubled hyphens
    [[ "$output" =~ ^draugr-[a-z0-9.-]+$ ]]
    [[ ! "$output" =~ -- ]]
}

@test "dr_sandbox_name: keeps periods, and a plus sign becomes a hyphen" {
    run dr_sandbox_name /mnt/c/Code/app.v2+beta
    [ "$output" = draugr-app.v2-beta ]
}

# The case of the repo folder used to be kept, and it decided for the life of
# the mound whether a kit could ever be added to it in place.
@test "dr_sandbox_name: lower-cases the name of the folder" {
    run dr_sandbox_name /mnt/c/Code/MyApp
    [ "$output" = draugr-myapp ]
}

@test "dr_sandbox_name: a folder of nothing but punctuation still gives a name" {
    run dr_sandbox_name "/mnt/c/Code/..."
    [ "$output" = draugr-mound ]
}

# The point of all of it: whatever the folder is called, the mound can take a
# kit in place. These are the shapes that broke the grammar of an image name.
@test "dr_sandbox_name: every name it derives can be an image name" {
    local leaf
    for leaf in MyApp "my project (old)" app.v2+beta "_under_" "...dots..." \
                "--hyphens--" "Ünïcödé" "CAPS" "a..b" "x+-.y" 42; do
        run dr_sandbox_name "/mnt/c/Code/$leaf"
        dr_sandbox_image_safe "$output" || {
            echo "not an image name: $leaf -> $output"
            return 1
        }
    done
}

# Nothing creates this one. dr-up and dr-ls use it to recognise a mound that an
# older Draugr built, which sbx cannot rename.
@test "dr_sandbox_name_legacy: keeps the case and the plus sign, as 0.9 did" {
    run dr_sandbox_name_legacy /mnt/c/Code/MyApp
    [ "$output" = draugr-MyApp ]
    run dr_sandbox_name_legacy /mnt/c/Code/app.v2+beta
    [ "$output" = draugr-app.v2+beta ]
}

# sbx names the image of an in-place kit add after the sandbox, and an image
# name is narrower than a sandbox name. These four say where the two differ.
@test "dr_sandbox_image_safe: a lower-case name can be an image name" {
    dr_sandbox_image_safe draugr-myproject
}

@test "dr_sandbox_image_safe: periods and hyphens between groups are allowed" {
    dr_sandbox_image_safe draugr-app.v2-beta
}

@test "dr_sandbox_image_safe: a capital letter is not" {
    ! dr_sandbox_image_safe draugr-Draugr || return 1
    ! dr_sandbox_image_safe draugr-unrealForge || return 1
}

# dr_sandbox_name used to keep a plus sign, and an image name has no place for
# one. That is why it stopped. A mound that an older Draugr built can still
# carry one, and is of the same kind as an upper-case one: no kit in place.
@test "dr_sandbox_image_safe: a plus sign is not, and an older name may hold one" {
    run dr_sandbox_name_legacy /mnt/c/Code/app.v2+beta
    [ "$output" = draugr-app.v2+beta ]
    ! dr_sandbox_image_safe "$output" || return 1
}

@test "dr_require_win_path: accepts a drive path" {
    run dr_require_win_path /mnt/c/Code/p
    [ "$status" -eq 0 ]
}

@test "dr_require_win_path: refuses ext4 with the reason" {
    run dr_require_win_path /home/user/code
    [ "$status" -ne 0 ]
    [[ "$output" == *"not on a Windows drive"* ]]
    [[ "$output" == *"/mnt/c"* ]]
}

# --- kits are the one thing allowed off a Windows drive -----------------------
#
# A workspace on the ext4 of WSL is not possible. The microVM cannot bind-mount
# a path behind the Windows network redirector. The host only READS a kit, then
# packs it, so the UNC form works for it. A test on sbx 0.37.1 showed this. A
# kit under ~/.config passed validation, ran its install command in the sandbox,
# and got its network rule.

@test "dr_path_win_kit: a Windows drive still gets the drive-letter form" {
    # If available, always use it. No network redirector, and no distro name
    # that can be wrong.
    run dr_path_win_kit /mnt/c/Code/kit
    [ "$status" -eq 0 ]
    [ "$output" = 'C:\Code\kit' ]
}

@test "dr_path_win_kit: an ext4 path gets the UNC form" {
    WSL_DISTRO_NAME=Ubuntu run dr_path_win_kit /home/me/.config/draugr/kits/lua
    [ "$status" -eq 0 ]
    [ "$output" = '\\wsl.localhost\Ubuntu\home\me\.config\draugr\kits\lua' ]
}

@test "dr_path_win_kit: the distro name is read, not assumed" {
    WSL_DISTRO_NAME=Debian run dr_path_win_kit /home/me/kit
    [ "$output" = '\\wsl.localhost\Debian\home\me\kit' ]
}

@test "dr_path_win_kit: fails when there is no distro to name" {
    # Better than a made-up name. If not, sbx rejects the path, with a message
    # about a distro that the user does not know.
    WSL_DISTRO_NAME= run dr_path_win_kit /home/me/kit
    [ "$status" -ne 0 ]
}

@test "dr_path_win: stays strict, because a WORKSPACE cannot use the UNC form" {
    # This guard must not regress. If this passes, Draugr accepts a repo on ext4
    # here, and it then fails deep inside sbx.
    WSL_DISTRO_NAME=Ubuntu run dr_path_win /home/me/project
    [ "$status" -ne 0 ]
}

# --- dr_path_canon_case -------------------------------------------------------
#
# These tests guard against a real bug. A repo trusted as
# /mnt/c/Code/draugr-gateway read as untrusted from /mnt/c/code/draugr-gateway.
# The only visible signs were a refused hook and a configuration that was
# silently skipped. The run then used defaults for all the values of that
# configuration.

@test "dr_path_canon_case: leaves a non-drive path alone" {
    # ext4 is case-sensitive. A case change here merges two different files.
    run dr_path_canon_case /home/me/Code/Project
    [ "$status" -eq 0 ]
    [ "$output" = /home/me/Code/Project ]
}

@test "dr_path_canon_case: leaves a bare drive root alone" {
    run dr_path_canon_case /mnt/c
    [ "$status" -eq 0 ]
    [ "$output" = /mnt/c ]
}

@test "dr_path_canon_case: keeps a component that is not on disk" {
    # It reports a spelling. It does not say that the path exists.
    run dr_path_canon_case /mnt/c/NoSuchDir-draugr-test/Nope
    [ "$status" -eq 0 ]
    [ "$output" = /mnt/c/NoSuchDir-draugr-test/Nope ]
}

@test "dr_path_canon_case: returns the spelling on disk, not the one asked for" {
    root=$(dr_win_root) || skip "no writable Windows drive path"
    # EXACTLY the name that dr_test_teardown makes, so this cannot leave a
    # directory on a real drive. Refer to the comment on dr_make_win_repo.
    dir="$root/draugr-test.${DR_TMP##*/}"
    mkdir -p "$dir/MixedCase/.draugr/hooks" || skip "cannot write to $root"

    # Asked for in the wrong case, with a DOTFILE component. That needs dotglob,
    # and the real bug failed on that component.
    run dr_path_canon_case "$dir/mixedcase/.DRAUGR/HOOKS"
    [ "$status" -eq 0 ]
    [ "$output" = "$dir/MixedCase/.draugr/hooks" ]
}

@test "dr_path_canon_case: an exact spelling survives unchanged" {
    root=$(dr_win_root) || skip "no writable Windows drive path"
    dir="$root/draugr-test.${DR_TMP##*/}"
    mkdir -p "$dir/MixedCase" || skip "cannot write to $root"

    run dr_path_canon_case "$dir/MixedCase"
    [ "$status" -eq 0 ]
    [ "$output" = "$dir/MixedCase" ]
}

@test "dr_path_canon_case: restores the glob options it needed" {
    # It sets dotglob and nullglob for its work, and noglob to split the path.
    # If one stays changed, globbing changes for each later caller. Such a bug
    # shows up far from here.
    shopt -u dotglob
    shopt -u nullglob
    set +f
    dr_path_canon_case /mnt/c/Windows >/dev/null
    run shopt -q dotglob
    [ "$status" -ne 0 ]
    run shopt -q nullglob
    [ "$status" -ne 0 ]
    case $- in *f*) false ;; *) true ;; esac
}

@test "trust survives the case the path was typed in" {
    # The full bug, end to end. Record a file by one spelling, and look it up by
    # another. The filesystem says that both name the same file.
    root=$(dr_win_root) || skip "no writable Windows drive path"
    dir="$root/draugr-test.${DR_TMP##*/}/MixedCase"
    mkdir -p "$dir" || skip "cannot write to $root"
    printf 'DRAUGR_AGENT=shell\n' > "$dir/.draugr.conf"

    dr_trust_add "$dir/.draugr.conf"
    run dr_trust_is_trusted "$dir/.draugr.conf"
    [ "$status" -eq 0 ]

    # The same file, named in another case. Before the fix, this returned 1.
    wrong=${dir/MixedCase/mixedcase}
    run dr_trust_is_trusted "$wrong/.draugr.conf"
    [ "$status" -eq 0 ]

    # And one record, in the canonical spelling, not two.
    run grep -c . "$DR_TRUST_FILE"
    [ "$output" = 1 ]
    run grep -cF "  $dir/.draugr.conf" "$DR_TRUST_FILE"
    [ "$output" = 1 ]
}

@test "trust records the canonical spelling even when given the wrong one" {
    root=$(dr_win_root) || skip "no writable Windows drive path"
    dir="$root/draugr-test.${DR_TMP##*/}/MixedCase"
    mkdir -p "$dir" || skip "cannot write to $root"
    printf 'DRAUGR_AGENT=shell\n' > "$dir/.draugr.conf"

    # Added by the WRONG spelling. The record must still use the spelling on
    # disk.
    wrong=${dir/MixedCase/mixedcase}
    dr_trust_add "$wrong/.draugr.conf"
    run grep -cF "  $dir/.draugr.conf" "$DR_TRUST_FILE"
    [ "$output" = 1 ]
}
