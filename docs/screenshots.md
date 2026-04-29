# Screenshot capture checklist

Working notes for the README screenshot pass. Delete this file once all
shots are captured and the README is updated.

## Prep

1. Run `./scripts/setup-screenshots.sh` — creates `~/tmp/uncommitted-demo/`
   with 7 demo repos covering every status-badge state.
2. Settings → Repositories → add `~/tmp/uncommitted-demo` as a source
   (scan depth 1).
3. Quit other source folders temporarily if they make the popover noisy
   (or just hide them with the "Hide repositories with no changes" toggle).
4. Set macOS appearance to whichever you want screenshots in. Light is
   safer for README readability; consider both.
5. After capturing: `./scripts/teardown-screenshots.sh` to clean up.

## Shots needed

All land in `docs/`. PNGs, retina (`@2x` not in filename — let macOS
screenshot tools save at native resolution).

| File | Subject | Capture how |
|---|---|---|
| `menubar.png` | Branch icon + `3` count in the menu bar itself | Cmd+Shift+5 → "Capture Selected Portion" → drag tight box around the menu-bar item only |
| `popover-mixed.png` | Full popover with the 7 demo repos visible | Open popover, Cmd+Shift+5 → drag around the popover window |
| `badges-closeup.png` | Tight crop of the `checkout` row (kitchen-sink: `↑2 ↓1 ★3 ● 2 + 1`) | After popover shot, crop that single row in Preview |
| `github-pills.png` | A real repo row showing `⤴ N / N` PR pill and `⚠️` or `🕐` CI badge | Use a real repo with an open PR + active CI; demo repos can't have these (no real GitHub remote) |
| `hover-detail.png` | Hover detail panel attached to a popover row, showing commit subjects | Hover any non-clean repo with commits to show, screenshot when panel is fully faded in |
| `settings-repositories.png` | Settings → Repositories tab with the demo source visible | Cmd+, → Repositories → window screenshot (Cmd+Shift+4 then Space then click window) |
| `settings-actions.png` | Settings → Actions tab with at least 3-4 actions incl. app icons | Settings → Actions → same window-screenshot trick |

## README integration (after shots are in)

Edit `README.md`:

- Line 6: `menubar.png` already referenced — should now resolve.
- After line 18 (end of "What it does" bullets): insert `popover-mixed.png`
  and `hover-detail.png` with captions.
- After line 49 (end of "Status badges" table): insert `badges-closeup.png`.
- After line 92 (end of "GitHub status" click sentence): insert `github-pills.png`.
- After line 165 (end of "Repositories" subsection): insert `settings-repositories.png`.
- After line 185 (end of "Actions" subsection): insert `settings-actions.png`.
- Lines 148-150 (the "currently ad-hoc signed, not notarized" note):
  delete entirely once v0.6 ships notarized.
