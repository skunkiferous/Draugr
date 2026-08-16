#!/usr/bin/env bats
# Path translation. One repository has three names and confusing them is the
# richest source of bugs in this tool, so the table is exhaustive on purpose.

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
    # letters, numbers, hyphens, periods, plus signs only; no doubled hyphens
    [[ "$output" =~ ^draugr-[A-Za-z0-9.+-]+$ ]]
    [[ ! "$output" =~ -- ]]
}

@test "dr_sandbox_name: keeps periods and plus signs" {
    run dr_sandbox_name /mnt/c/Code/app.v2+beta
    [ "$output" = draugr-app.v2+beta ]
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
# A workspace on WSLs

# --- kits are the one thing allowed off a Windows drive -----------------------
#
# A workspace on WSL's ext4 is impossible - the microVM cannot bind-mount a path
# behind the Windows network redirector. A kit is only READ on the host and then
# packed, so the UNC form works for it. Measured against sbx 0.37.1: a kit under
# ~/.config validated, ran its install command inside the sandbox, and had its
# network rule applied.

@test "dr_path_win_kit: a Windows drive still gets the drive-letter form" {
    # Always preferable when available: no network redirector involved, and no
    # distro name to be wrong about.
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
    # Better than inventing one: sbx would otherwise reject the path with a
    # message about a distro the user has never heard of.
    WSL_DISTRO_NAME= run dr_path_win_kit /home/me/kit
    [ "$status" -ne 0 ]
}

@test "dr_path_win: stays strict, because a WORKSPACE cannot use the UNC form" {
    # The guard that must not regress. If this ever starts succeeding, a repo on
    # ext4 would be accepted here and then fail deep inside sbx.
    WSL_DISTRO_NAME=Ubuntu run dr_path_win /home/me/project
    [ "$status" -ne 0 ]
}
