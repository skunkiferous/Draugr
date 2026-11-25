# shellcheck shell=bash
# Native Codex libraries contain published local marketplaces, not a host
# CODEX_HOME. Only disposable mounds fetch or install third-party code.

# Names become path components and TOML keys. Validate before constructing
# either, including names that a marketplace returned rather than the user.
#
# dr_simple_name is the one definition of that rule (lib/common.sh). This file
# had its own copy, which refused one case fewer: a name beginning with `-`,
# which the next command reads as an option, and a name of nothing but dots.
_dr_cp_name() {
    dr_simple_name "$1"
}

# The native CLI works in rootfs, under an empty home that contains no login.
_dr_cp_native() {
    dr_sbx exec "$_cp_mound" -- env "CODEX_HOME=$_cp_work/home" codex plugin "$@" --json </dev/null
}

# TWO DIRECTORIES, AND THE DIFFERENCE IS THE POINT.
#
#   $_cp_build   the WORKSPACE of the build mound. The sandbox writes here.
#                The host creates it, hands it to sbx, and reads nothing out
#                of it, ever.
#   $_cp_stage   the library under construction. HOST ONLY. No mound is given
#                this path, and the final rename publishes it.
#
# They used to be one directory. The host wrote library.json, library.json.next
# and every marketplace catalog inside the workspace of the mound itself, and then
# published that tree by renaming it. A security review showed the consequence:
# a link placed at `library.json.next` redirects the `jq … > $tmp` of the host to
# whatever the link points at, and no amount of validating plugin NAMES can see
# that, because the name was never the problem. It also means the published
# library was a tree that a sandbox was able to edit between the check and the rename.
#
# Keeping the two apart removes the question instead of guarding it. The
# exported package bytes still come from the mound (they are the product),
# but they arrive by `sbx cp` into a path the host chose, and the whole staged
# tree is validated before anything is published.
#
# Clean up only the resources of this transaction. A failed build never touches
# the live library; a collision refuses before the trap is installed.
_dr_cp_stop_mound() {
    [ -n "${_cp_created:-}" ] || return 0
    _cp_created=''
    dr_sbx rm --force "$_cp_mound" >/dev/null 2>&1 || dr_warn "could not remove $_cp_mound"
}

_dr_cp_cleanup() {
    _dr_cp_stop_mound
    if [ -n "${_cp_locked:-}" ]; then rmdir "$_cp_root/.lock" 2>/dev/null || true; fi
}

# Copy existing published bytes so adding one plugin does not update others.
_dr_cp_begin() {
    local d
    mkdir -p "$_cp_root"
    mkdir "$_cp_root/.lock" || dr_die "another Codex plugin transaction holds $_cp_root/.lock"
    _cp_locked=1
    trap _dr_cp_cleanup EXIT
    for d in "$_cp_build" "$_cp_stage"; do
        if [ -e "$d" ]; then
            [ -n "${force:-}" ] || dr_die "a previous build remains at $d" "Retry with --force after checking it."
            rm -rf "$d"
        fi
    done
    # The workspace is created EMPTY. Nothing of the library goes into it, so
    # there is nothing in there for the sandbox to tamper with.
    mkdir -p "$_cp_build" "$_cp_stage/seed"
    if [ -d "$_cp_seed" ]; then
        cp -a "$_cp_seed/." "$_cp_stage/seed/"
        # `cp -a` copies a link AS A LINK, so the published library decides
        # what the staged one contains. A library from an older Draugr was
        # never checked for links, and the very first host write below is
        # `library.json.next`, the name the review redirected. So the tree is
        # judged BEFORE anything writes into it, not only before it publishes.
        dr_incoming_validate_tree "$_cp_stage/seed" || dr_die \
            "the Codex library contains a link or an unsupported file" \
            "Draugr will not write into a tree whose names point elsewhere." \
            "It is copied as it was, in $_cp_stage/seed. Your library is unchanged."
    fi
    _cp_json="$_cp_stage/seed/library.json"
    if [ ! -f "$_cp_json" ]; then printf '{"format":1,"marketplaces":{},"plugins":[]}\n' > "$_cp_json"; fi
}

# The probe for the version and the command runs in the build mound, never on the host.
_dr_cp_start() {
    [ -z "${_cp_created:-}" ] || return 0
    dr_sandbox_exists "$_cp_mound" && dr_die "$_cp_mound already exists" "Inspect and remove that test or build mound first."
    _cp_created=1
    dr_sbx create --name "$_cp_mound" --memory "${DRAUGR_MEMORY:-4g}" codex "$(dr_path_win "$_cp_build")" || dr_die "could not create the Codex plugin build mound"
    dr_sbx exec "$_cp_mound" -- mkdir -p "$_cp_work/home" || dr_die "could not prepare plugin home"
    dr_sbx exec "$_cp_mound" -- codex plugin --help >/dev/null || dr_die "the Codex in this mound has no native plugin CLI" "Use a template with Codex plugin support."
}

# Export only the installed package. The config, the auth and the writable
# plugin data of the CLI never cross the boundary with it.
_dr_cp_install() {
    local id=$1 result path ver plug mkt dest tmp
    plug=${id%@*}; mkt=${id#*@}
    if ! _dr_cp_name "$plug" || ! _dr_cp_name "$mkt"; then dr_die "unsafe plugin identity: $id"; fi
    result=$(_dr_cp_native add "$id") || dr_die "Codex could not install $id"
    path=$(printf '%s' "$result" | jq -er .installedPath) || dr_die "Codex did not report an installed path"
    ver=$(printf '%s' "$result" | jq -er .version) || dr_die "Codex did not report a version"
    _dr_cp_name "$ver" || dr_die "unsafe plugin version: $ver"
    case "$path" in "$_cp_work/home/plugins/cache/$mkt/$plug/$ver") ;; *) dr_die "unexpected Codex install path: $path" ;; esac
    dest="$_cp_stage/seed/marketplaces/$mkt/packages/$plug"
    mkdir -p "$dest"
    # The names above are simple names, so this path cannot traverse. That is
    # not the same as "this path is where it looks": a link anywhere along it
    # points elsewhere with an innocent name. The deletion below is the reason
    # to ask.
    dr_path_contained "$_cp_stage" "$dest" || dr_die \
        "the staged package directory of $id is not inside $_cp_stage" \
        "Nothing was deleted or published."
    # Copying into a fresh version path avoids merging a removed upstream file
    # back into a new package that happens to use the same version string.
    rm -rf "${dest:?}/${ver:?}"
    dr_sbx cp "$_cp_mound:$path" "$(dr_path_win "$dest")" || dr_die "could not export $id"
    dr_incoming_validate_tree "$dest/$ver" || dr_die "plugin contains links or unsupported files: $id"
    tmp="$_cp_json.next"
    jq --arg id "$id" --arg name "$plug" --arg m "$mkt" --arg v "$ver" \
        '([.plugins[] | select(.id == $id)] | first) as $old |
         .plugins = ([.plugins[] | select(.id != $id)] + [{id:$id,name:$name,marketplace:$m,version:$v,enabled:(if $old == null then true else $old.enabled end)}]) |
         .removed = ((.removed // []) | map(select(. != $id)))' \
        "$_cp_json" > "$tmp" || dr_die "could not record $id"
    mv "$tmp" "$_cp_json"
}

# Native local source paths stay within one published marketplace root.
# All content is read-only on consumers. Their caches and auth remain private.
_dr_cp_catalogs() {
    local m dir
    while IFS= read -r m; do
        _dr_cp_name "$m" || dr_die "unsafe marketplace identity"
        dir="$_cp_stage/seed/marketplaces/$m/.agents/plugins"
        mkdir -p "$dir"
        jq --arg m "$m" '{name:$m,plugins:[.plugins[] | select(.marketplace == $m) |
            {name:.name,source:{source:"local",path:("./packages/"+.name+"/"+.version)},
             policy:{installation:"AVAILABLE",authentication:"ON_INSTALL"},category:"Productivity"}]}' \
            "$_cp_json" > "$dir/marketplace.json" || dr_die "could not publish $m"
    done < <(jq -r '.marketplaces | keys[]' "$_cp_json")
}

# Publish by rename after every native operation and artifact check succeeded.
#
# THE WRITER STOPS BEFORE THE TREE IS JUDGED. The staged library is already
# out of reach of the build mound, and stopping it first keeps that true
# whatever a later change does to the layout: a check is worth nothing if
# something can still edit what was checked afterwards.
#
# Then the WHOLE tree, not only the package subdirectory that each install
# validated. A catalog, a receipt or a leftover from an earlier version is as
# much a part of what gets published as the packages are.
_dr_cp_commit() {
    _dr_cp_catalogs
    _dr_cp_stop_mound
    dr_incoming_validate_tree "$_cp_stage/seed" || dr_die \
        "the built Codex library contains a link or an unsupported file" \
        "Nothing was published. The build is in $_cp_stage/seed. Look at it there."
    # The same three questions the other two channels ask, in the same order:
    # what shape, how much, and where. A plugin library is small, so the limit
    # is not what anybody here will meet, and that is the point of a ceiling that
    # is shared rather than guessed for each channel.
    dr_incoming_within_limits "$_cp_stage/seed" || dr_die \
        "the built Codex library is larger than this host accepts" \
        "Nothing was published. The line above names the key that raises the limit." \
        "The build is in $_cp_stage/seed. Look at it there."
    dr_incoming_dest_ok "$_cp_root" "$_cp_seed" || dr_die \
        "the Codex library is not the place it names" \
        "Nothing was published. The line above says which part of it." \
        "The build is in $_cp_stage/seed. Look at it there."
    # One swap, shared with the memory export, with seed.old as the name that this
    # library uses for the copy it replaces.
    dr_incoming_publish "$_cp_stage/seed" "$_cp_seed" "$_cp_root/seed.old" || dr_die \
        "the built Codex library could not be put in place" \
        "Your library is as it was. The build is in $_cp_stage/seed."
    rm -rf "$_cp_stage" "$_cp_build"
    dr_ok "Codex plugin library updated; previous library is in $_cp_root/seed.old"
}

# Refresh a source only when adding or updating its plugins. Previously
# published packages in other marketplaces stay byte-for-byte unchanged.
_dr_cp_register() {
    local source=$1 native_source=$1 result m tmp key
    _dr_cp_start
    if [ -d "$source" ]; then
        # A local marketplace must be a dedicated package source. Copy it to
        # this build mound. Do not expose any additional host workspace.
        dr_incoming_validate_tree "$source" || dr_die "local marketplace contains links or special files"
        key=$(printf '%s' "$source" | sha256sum | cut -c1-16)
        dr_sbx exec "$_cp_mound" -- mkdir -p "$_cp_work/sources/$key" || dr_die "could not stage marketplace"
        dr_sbx cp "$(dr_path_win "$source")" "$_cp_mound:$_cp_work/sources/$key/" || dr_die "could not copy marketplace"
        native_source="$_cp_work/sources/$key/${source##*/}"
    fi
    result=$(_dr_cp_native marketplace add "$native_source") || dr_die "Codex could not register $source"
    m=$(printf '%s' "$result" | jq -er .marketplaceName) || dr_die "Codex reported no marketplace name"
    _dr_cp_name "$m" || dr_die "unsafe marketplace name: $m"
    tmp="$_cp_json.next"
    jq --arg m "$m" --arg s "$source" '.marketplaces[$m]=$s' "$_cp_json" > "$tmp" || dr_die "could not record marketplace"
    mv "$tmp" "$_cp_json"
    _cp_market=$m
}

# Inspect and operate on an agent-specific corner without changing the legacy
# Claude library at the root of DRAUGR_PLUGIN_STORE.
dr_codex_plugins() {
    local action=$1 id state source m tmp row name ver script slug dir mount
    shift
    [ -n "$DRAUGR_PLUGIN_STORE" ] || dr_die "DRAUGR_PLUGIN_STORE is not set" "Set a plugin store on a Windows drive."
    dr_require_win_path "$DRAUGR_PLUGIN_STORE"
    local _cp_root="$DRAUGR_PLUGIN_STORE/codex" _cp_work=/home/agent/draugr-plugins
    local _cp_mound="$DRAUGR_SANDBOX-plugin-build-codex" _cp_created='' _cp_locked='' _cp_market=''
    local _cp_seed="$_cp_root/seed" _cp_build="$_cp_root/.build" _cp_stage="$_cp_root/.stage"
    local _cp_json="$_cp_root/seed/library.json"
    local ids=()
    case "$action" in
    status|list)
        if [ -f "$_cp_json" ]; then
            jq -r '.plugins[] | "\(.id) \(.version) \(if .enabled then "enabled" else "disabled" end)"' "$_cp_json"
        fi
        if [ "$action" = status ]; then
            dr_info "Codex library: $_cp_seed"
            dr_info "Mount it read-only: DRAUGR_MOUNTS=\"$_cp_root:ro\""
            dr_info "Use dr-plugin kit to install it in each mound. Switches apply at dr-go."
        fi
        ;;
    skills) dr_codex_plugin_skills "$DRAUGR_PLUGIN_STORE" ;;
    add)
        [ $# -gt 0 ] || dr_die "add needs a marketplace source"
        source=$1; shift
        _dr_cp_begin
        _dr_cp_register "$source"
        m=$_cp_market
        if [ $# -gt 0 ]; then
            for id in "$@"; do
                case "$id" in *@*) ids+=("$id") ;; *) ids+=("$id@$m") ;; esac
            done
        else
            row=$(_dr_cp_native list --available) || dr_die "could not list marketplace plugins"
            mapfile -t ids < <(printf '%s' "$row" | jq -r --arg m "$m" '.available[] | select(.marketplaceName == $m) | .pluginId')
        fi
        [ ${#ids[@]} -gt 0 ] || dr_die "no plugins selected from $m" "Name plugins explicitly to add an already installed package."
        for id in "${ids[@]}"; do _dr_cp_install "$id"; done
        _dr_cp_commit
        ;;
    update)
        [ -f "$_cp_json" ] || dr_die "the Codex library is empty"
        if [ $# -gt 0 ]; then ids=("$@"); else mapfile -t ids < <(jq -r '.plugins[].id' "$_cp_json"); fi
        _dr_cp_begin
        for id in "${ids[@]}"; do
            m=${id#*@}
            source=$(jq -er --arg m "$m" '.marketplaces[$m]' "$_cp_json") || dr_die "unknown marketplace: $m"
            _dr_cp_register "$source"
            _dr_cp_install "$id"
        done
        _dr_cp_commit
        ;;
    remove|enable|disable)
        if [ $# -eq 0 ] || [ ! -f "$_cp_json" ]; then dr_die "$action needs an installed plugin"; fi
        _dr_cp_begin
        for id in "$@"; do
            jq -e --arg id "$id" '.plugins[] | select(.id==$id)' "$_cp_json" >/dev/null || dr_die "not installed: $id"
            tmp="$_cp_json.next"
            if [ "$action" = remove ]; then
                jq --arg id "$id" '.plugins |= map(select(.id!=$id)) |
                    .removed = (((.removed // []) + [$id]) | unique)' "$_cp_json" > "$tmp"
                dr_warn "generated kits can still install $id; remove them from DRAUGR_KIT"
            else
                state=false; [ "$action" != enable ] || state=true
                jq --arg id "$id" --argjson v "$state" '(.plugins[] | select(.id==$id)).enabled=$v' "$_cp_json" > "$tmp"
            fi
            mv "$tmp" "$_cp_json"
        done
        _dr_cp_commit
        ;;
    rollback)
        [ -d "$_cp_root/seed.old" ] || dr_die "there is no previous Codex library"
        dr_confirm "Swap the current and previous Codex plugin libraries?" || dr_die "cancelled"
        mkdir "$_cp_root/.lock" || dr_die "another plugin transaction holds the library"
        _cp_locked=1; trap _dr_cp_cleanup EXIT
        mv "$_cp_seed" "$_cp_root/.swap"
        mv "$_cp_root/seed.old" "$_cp_seed"
        mv "$_cp_root/.swap" "$_cp_root/seed.old"
        ;;
    clean)
        [ -f "$_cp_json" ] || return 0
        _dr_cp_begin
        # Work on a copy, and keep only versions named by its own receipt.
        while IFS= read -r dir; do
            row=${dir#"$_cp_stage/seed/marketplaces/"}
            m=${row%%/*}; row=${row#*/packages/}; name=${row%%/*}; ver=${row#*/}
            if ! jq -e --arg m "$m" --arg n "$name" --arg v "$ver" '.plugins[] | select(.marketplace==$m and .name==$n and .version==$v)' "$_cp_json" >/dev/null; then
                # The copy is host-only, and find does not follow links. Ask
                # anyway: this is a deletion, and the answer costs nothing.
                dr_path_contained "$_cp_stage" "$dir" || dr_die \
                    "a staged package directory is not inside $_cp_stage: $dir" \
                    "Nothing was deleted."
                rm -rf "$dir"
            fi
        done < <(find "$_cp_stage/seed/marketplaces" -mindepth 4 -maxdepth 4 -type d 2>/dev/null)
        _dr_cp_commit
        ;;
    kit)
        [ -f "$_cp_json" ] || dr_die "the Codex library is empty"
        if [ $# -gt 0 ]; then ids=("$@"); else mapfile -t ids < <(jq -r '.plugins[].id' "$_cp_json"); fi
        for id in "${ids[@]}"; do
            row=$(jq -er --arg id "$id" '.plugins[] | select(.id==$id) | [.name,.marketplace] | @tsv' "$_cp_json") || dr_die "not installed: $id"
            read -r name m <<< "$row"
            slug=$(dr_kit_slug "codex-$m-$name")
            dir="$(dr_kit_store)/plugin-$slug"
            if [ -e "$dir" ] && [ -z "${force:-}" ]; then dr_confirm "Overwrite $dir?" || continue; fi
            mkdir -p "$dir"
            mount=$(dr_path_mound "$_cp_seed/marketplaces/$m")
            script="env HOME=/home/agent codex plugin marketplace add $(dr_shquote "$mount") && env HOME=/home/agent codex plugin add $(dr_shquote "$id")"
            # A JSON string is a valid YAML scalar, including escaped quotes.
            {
                printf '# syntax=docker/sandbox-kit:3\nschemaVersion: "3"\nkind: mixin\ncapabilities:\n'
                printf '  - type: com.docker.sandbox/lifecycle@1\n    config:\n      install:\n'
                printf '        - command: %s\n          user: "1000"\n' "$(jq -Rn --arg v "$script" '$v')"
                printf '          description: Install %s from the local Codex library\n' "$id"
            } > "$dir/spec.yaml"
            dr_ok "wrote $dir/spec.yaml"
        done
        dr_info "Mount $_cp_root read-only, validate the kits, then add them to DRAUGR_KIT."
        ;;
    *) dr_die "unsupported Codex plugin action: $action" ;;
    esac
    # Finish while the local paths and the ownership of the transaction are in scope.
    # EXIT still handles a failed command that ended the shell earlier.
    _dr_cp_cleanup
    trap - EXIT
}
