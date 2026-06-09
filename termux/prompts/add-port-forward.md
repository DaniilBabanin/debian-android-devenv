# Prompt — wire up a new port forward over the PC tunnel

Reusable prompt for adding a `LocalForward` to the phone→PC ssh tunnel (the
`pc-fwd` autossh setup), on this device later or on a fresh device. Copy the
block below into Claude Code running **inside the proot Debian guest**, fill in
`<PORT>` (and `<REMOTE_PORT>` if it differs), and send.

---

You're inside the Termux proot Debian guest. Wire up a new local port forward so
the phone can reach a service running on the PC through the existing cloudflared
ssh tunnel.

Forward: phone `localhost:<PORT>` → PC `localhost:<REMOTE_PORT>`
(if `<REMOTE_PORT>` not given, assume same as `<PORT>`).

The 8001/8080 forwards already in place are the reference. Add the new one
**everywhere the existing forwards live**, exactly the same way:

1. **Repo source of truth (persistence):** `modules/install-vscode.sh`, the
   `pc-fwd` ssh stanza (heredoc that writes it, around the `LocalForward 8001
   localhost:8000` line). Add `LocalForward <PORT> localhost:<REMOTE_PORT>`
   right after the existing forwards so a rebuild regenerates it.

2. **Live `~/.ssh/config`:** add the same line to the `Host pc-fwd` stanza.
   First CHECK the stanza actually exists and is complete — the live file has
   been seen reduced to just the bare `Host ssh.babanin.de` stanza, with `pc`
   and `pc-fwd` only surviving in `~/.ssh/config.bak`. If `pc`/`pc-fwd` are
   missing, restore them from `config.bak` before adding the new forward.
   `chmod 600 ~/.ssh/config` after.

3. **Restart the tunnel** so the new forward takes effect:
   - `pkill -f "autossh -M 0 -N pc-fwd"; pkill -f "ssh -N pc-fwd"` then confirm
     no survivors.
   - Restart: `AUTOSSH_GATETIME=0 AUTOSSH_POLL=30 nohup autossh -M 0 -N pc-fwd
     >/tmp/pc-fwd.out 2>&1 &` (durable path is the widget /
     `tmux new -d -s pc-tunnel pc-tunnel` — mention it).

4. **Verify with `curl`, NOT `ss`.** `ss`/`netstat` are blind inside proot
   (no `/proc/net` virtualization) and will show NONE even when the forward is
   up. Confirm with:
   `curl -s -o /dev/null -w "HTTP %{http_code}\n" --max-time 8 http://localhost:<PORT>/`
   Expect a real HTTP code (200/302/401/etc.), not "no answer".

5. **Open it:** `termux-open-url "http://localhost:<PORT>"` — this works from
   inside the guest (it's the Termux binary on the bound PATH).

Gotchas to respect:
- `ExitOnForwardFailure yes` is set on `pc-fwd`: if ANY forwarded port can't
  bind (something already squats it on the phone), the WHOLE tunnel dies,
  taking every other forward with it. Before adding a port, make sure nothing
  on the phone already owns it. Note the known clash: phone `:8080` is also the
  local `code-server` (`code-local`) port — never run `code-local` and an 8080
  tunnel forward at the same time.
- Android squats some low ports (e.g. 8000), which is why the PC's 8000 maps to
  phone 8001. If a chosen phone port won't bind, pick another and forward it to
  the same remote port.
- Append-only when touching `~/.ssh/config`; never clobber an existing stanza.

Report: the curl HTTP code for the new port, and confirm the existing forwards
(8001, 8080) still answer (the restart shouldn't have dropped them).
