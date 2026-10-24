#!/usr/bin/env bash
# The installed pipeline venv (DIST4). Sourced, not run; shared by install.sh,
# rebuild.sh and scripts/test-app-relocation.sh, so the fence tests the same
# command the installer runs.
#
# The venv is a real, non-editable install synced in place at its final path,
# so nothing in it points back at the git clone. It used to be `uv sync` in
# pipeline/ followed by `cp -R pipeline/.venv`, and that copy was a launcher
# back into the clone: uv installs the project editable by default, so
# site-packages carried a .pth naming <repo>/pipeline/src, and bin/mp exec'd
# the clone's own .venv interpreter. A git pull or an uncommitted edit changed
# production Python while the Swift binary stayed old, and moving the clone
# broke every pipeline run.

# sync_pipeline_venv <pipeline_dir> <venv_path>
#   Create or update the venv at <venv_path> from <pipeline_dir>'s uv.lock,
#   non-editable, with the MCP extra. Returns non-zero when the lock cannot be
#   installed as-is, or when mp would still import from anywhere but the venv.
#   Every step returns explicitly: a caller writing `sync_pipeline_venv ... ||
#   die` switches `set -e` off inside the function.
sync_pipeline_venv() {
    local pipeline_dir="$1" venv="$2" imported_from

    # A venv left by the old `cp -R` has console scripts whose interpreter is the
    # clone's own .venv, wherever the clone was then, and uv sync would keep
    # them. A venv this function made names its own interpreter, so anything
    # else is started over.
    if [[ -e "$venv" ]] && ! grep -qF "$venv/bin/python" "$venv/bin/mp" 2>/dev/null; then
        rm -rf "$venv"
    fi

    # --frozen installs exactly the lock and never re-resolves (a re-resolve
    # rewrites uv.lock in the clone, which the old `2>/dev/null || uv sync`
    # fallback did silently). --no-editable builds the project into a wheel.
    # --reinstall-package rebuilds it every time: uv caches a local project's
    # build by pyproject.toml's mtime, so a source edit alone would not reach
    # the venv. --extra mcp (AUTO3): the MCP SDK is an optional extra so the
    # dependency is not forced on anyone who never serves, but this Mac is the
    # one that runs `mp mcp-serve`; the server still refuses to start unless
    # `[mcp] enabled` is on.
    UV_PROJECT_ENVIRONMENT="$venv" uv sync \
        --project "$pipeline_dir" \
        --frozen --no-editable --reinstall-package meeting-pipe --extra mcp \
        || return 1

    # Prove it, rather than trusting the flags: from a neutral cwd and isolated
    # from PYTHONPATH and the user site, mp must import from inside the venv.
    # An editable .pth would send it back to the source tree.
    imported_from="$(cd / && "$venv/bin/python3" -I -c 'import mp; print(mp.__file__)')" || return 1
    if [[ "$imported_from" != "$venv/"* ]]; then
        printf '\033[1;31mxx\033[0m %s\n' \
            "mp imports from $imported_from, not from $venv: the installed pipeline is still bound to the source tree." >&2
        return 1
    fi
}
