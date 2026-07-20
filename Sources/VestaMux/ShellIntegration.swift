import Foundation

/// Out-of-the-box OSC 133 shell integration for shells the daemon spawns itself.
///
/// vestad forkpty's a login shell directly (see Session.swift) — it is NOT launched by
/// ghostty, so ghostty's automatic shell integration never runs and no OSC 133 command
/// marks are emitted. Without those marks the sidebar's per-session "heat" (the ✓/✗ that
/// reflects the last command's exit status, parsed by TailStore.lastExitMarker) silently
/// never lights up.
///
/// This ships our own tiny, MIT-clean zsh integration and injects it via the ZDOTDIR swap —
/// zero user configuration. It depends on NOTHING from ghostty's resources (vestad also runs
/// standalone). Only zsh is wired up (macOS default); bash/fish degrade gracefully — the
/// attention rail still works, they just don't get ✓/✗ heat.
public enum VestaShellIntegration {

    /// The `.zshenv` we drop into the ZDOTDIR we point zsh at. zsh sources this automatically
    /// (that's the whole point of the ZDOTDIR swap). It must, in order:
    ///   1. Restore the user's real ZDOTDIR so their .zprofile/.zshrc/.zlogin load unchanged.
    ///   2. Source the user's own .zshenv (zsh would have; we shadowed its dir).
    ///   3. For interactive shells, register minimal OSC 133 preexec/precmd hooks.
    ///
    /// Ordering rationale (the hard part — must survive oh-my-zsh / powerlevel10k):
    /// we register via `add-zsh-hook` (the precmd_functions/preexec_functions ARRAYS), never a
    /// bare `precmd()`/`preexec()` definition. Frameworks redefine the bare functions but only
    /// ever APPEND to the arrays, so array hooks are never clobbered. Registering here at
    /// .zshenv time — BEFORE .zshrc runs — also lands _vesta_precmd FIRST in precmd_functions,
    /// so it reads `$?` before any framework precmd runs a command and clobbers it, keeping the
    /// reported exit status accurate. (Ghostty defers to first-precmd to sit LAST for prompt
    /// marking; we emit no prompt marks and care only about an accurate exit code, so FIRST is
    /// what we want.)
    public static let zshEnv = """
    # Vesta zsh shell integration (auto-generated; safe to delete — new shells then skip
    # integration until the next vestad restart regenerates it).
    #
    # vestad spawns login shells directly, so ghostty's automatic shell integration never
    # runs here. This restores your normal zsh startup, then emits OSC 133 command marks so
    # the Vesta sidebar can show per-session exit ✓/✗ heat. Injected via a ZDOTDIR swap; this
    # file is sourced automatically by zsh. See VestaShellIntegration in the Vesta source.

    # --- 1. Restore the user's real ZDOTDIR so the rest of startup is unaffected. ---
    # vestad passes the original in VESTA_ORIG_ZDOTDIR, and only when the user actually had
    # one. Zsh treats an unset ZDOTDIR as $HOME, so unsetting is the faithful default.
    if [[ -n "${VESTA_ORIG_ZDOTDIR+X}" ]]; then
      builtin export ZDOTDIR="$VESTA_ORIG_ZDOTDIR"
      builtin unset VESTA_ORIG_ZDOTDIR
    else
      builtin unset ZDOTDIR
    fi

    # --- 2. Source the user's own .zshenv. ---
    # zsh would have sourced it from the (now restored) ZDOTDIR; we shadowed that dir, so do
    # it ourselves. Runs for non-interactive shells too, so scripts stay intact. Missing or
    # unreadable files are skipped, exactly as zsh does.
    _vesta_user_zshenv="${ZDOTDIR:-$HOME}/.zshenv"
    [[ -r "$_vesta_user_zshenv" ]] && builtin source "$_vesta_user_zshenv"
    builtin unset _vesta_user_zshenv

    # --- 3. Interactive-only: OSC 133 command marks for sidebar heat. ---
    # Skip if any integration already handles this (ghostty's own, or a second Vesta
    # injection) so we never double-emit. Claim it via VESTA_SHELL_INTEGRATION.
    if [[ -o interactive ]] && [[ -z "$GHOSTTY_SHELL_INTEGRATION" ]] && [[ -z "$VESTA_SHELL_INTEGRATION" ]]; then
      builtin export VESTA_SHELL_INTEGRATION=1

      # A command is about to run → mark command start.
      _vesta_preexec() { builtin print -n '\\e]133;C\\a' }

      # The last command just finished → mark command end + its exit status.
      _vesta_precmd() {
        builtin local -i _vesta_status=$?   # capture $? on the VERY FIRST line
        # Some plugins invoke precmd from zle to redraw the prompt; that isn't a real
        # command completion, so don't emit a bogus exit mark then.
        builtin zle && return
        builtin print -n '\\e]133;D;'"$_vesta_status"'\\a'
      }

      # Register on the ARRAYS via add-zsh-hook (never bare precmd()/preexec(), which
      # frameworks like oh-my-zsh / powerlevel10k overwrite). Registering at .zshenv time
      # also places _vesta_precmd first, so $? is read before any framework precmd clobbers it.
      builtin autoload -Uz add-zsh-hook
      add-zsh-hook preexec _vesta_preexec
      add-zsh-hook precmd _vesta_precmd
    fi
    """

    /// Write the generated integration files under the mux state dir (write-if-changed, so a
    /// version bump ships but we don't churn the file — or clobber a shell mid-source — every
    /// startup). Called once at daemon startup. Best-effort: a write failure just means heat
    /// stays dark, never a spawn failure.
    public static func ensure() {
        let dir = MuxPaths.shellIntegrationZsh
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let path = dir + "/.zshenv"
        let current = try? String(contentsOfFile: path, encoding: .utf8)
        guard current != zshEnv else { return }
        try? zshEnv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Is `shellPath` a zsh (the only shell we inject into)? Matches the executable's basename
    /// so /bin/zsh, /usr/bin/zsh, a Homebrew /opt/homebrew/bin/zsh, etc. all count.
    public static func isZsh(_ shellPath: String) -> Bool {
        (shellPath as NSString).lastPathComponent == "zsh"
    }

    /// The exact OSC 133 command-done byte sequence our generated `.zshenv` emits for exit
    /// `status` (ESC ] 133 ; D ; <status> BEL). Single source of truth shared with the
    /// TailStore parser test — if the script's mark and the parser ever drift, a selfcheck
    /// fails. The `\\e`/`\\a` in the script literal ARE these ESC/BEL bytes at runtime.
    public static func doneMark(_ status: Int) -> String { "\u{1B}]133;D;\(status)\u{07}" }
}

/// Pure-logic check for the generated zsh integration script (run by `vesta selfcheck`).
public func shellIntegrationSelfCheck() {
    let s = VestaShellIntegration.zshEnv
    // Hooks go through add-zsh-hook on the arrays, never bare precmd()/preexec().
    assert(s.contains("add-zsh-hook precmd _vesta_precmd"), "registers precmd via add-zsh-hook")
    assert(s.contains("add-zsh-hook preexec _vesta_preexec"), "registers preexec via add-zsh-hook")
    assert(s.contains("autoload -Uz add-zsh-hook"), "autoloads add-zsh-hook")
    // The command-done mark carries the exit status; the runtime bytes are ESC…BEL.
    assert(s.contains("]133;D;"), "emits the 133;D exit mark")
    assert(s.contains("]133;C"), "emits the 133;C command-start mark")
    assert(s.contains("_vesta_status=$?"), "captures $? before anything can clobber it")
    // Double-install guard + our own env claim.
    assert(s.contains("GHOSTTY_SHELL_INTEGRATION"), "skips if ghostty already integrated")
    assert(s.contains("VESTA_SHELL_INTEGRATION=1"), "claims VESTA_SHELL_INTEGRATION")
    // ZDOTDIR restore so the user's normal startup is unaffected.
    assert(s.contains("VESTA_ORIG_ZDOTDIR"), "restores the user's ZDOTDIR")
    assert(s.contains("builtin source \"$_vesta_user_zshenv\""), "sources the user's real .zshenv")
    // Shell detection: only zsh basenames match.
    assert(VestaShellIntegration.isZsh("/bin/zsh"), "/bin/zsh is zsh")
    assert(VestaShellIntegration.isZsh("/opt/homebrew/bin/zsh"), "homebrew zsh is zsh")
    assert(!VestaShellIntegration.isZsh("/bin/bash"), "bash is not zsh")
    assert(!VestaShellIntegration.isZsh("/usr/bin/fish"), "fish is not zsh")
    assert(VestaShellIntegration.doneMark(0) == "\u{1B}]133;D;0\u{07}", "done mark bytes")
    print("shellIntegrationSelfCheck OK")
}
