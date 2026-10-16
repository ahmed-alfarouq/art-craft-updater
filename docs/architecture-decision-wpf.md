# Architecture Decision: WPF on .NET 9 for ArtCraft Updater

Status: **Approved** (Phase 2A). Date: 2026-10-15.

## Decision

Rebuild the ArtCraft Updater presentation layer in **WPF on .NET 9** (C#, XAML,
MVVM without a framework to start). Keep the PowerShell update engine
(`ArtCraftInstall.psm1`, `ArtCraftUpdater.Controller.psm1`, registry,
manifests) untouched behind the future out-of-process JSON bridge.

## Rationale

- Full styling/templating control with zero extra runtimes: self-contained or
  framework-dependent `.exe` via `dotnet publish`; .NET 9 Desktop runtime is
  already on this machine.
- Mature RTL (`FlowDirection`), satellite-assembly localization, and Narrator
  support match the Arabic + English requirement with documented patterns.
- MIT-licensed, Microsoft-maintained framework; no commercial hooks, no Store
  or MSIX requirement, no 250 MB WebView2 payload, no App-SDK bootstrapper.
- Smallest migration risk: only the ~450-line WinForms GUI is rewritten; all
  127 engine tests and every safety guarantee stay valid.
- Fallback if WPF ever blocks: Avalonia (same XAML/MVVM shape, new dialect).

## Engine-preservation boundary

The WPF app must never implement hashing, signature checks, staging,
rollback, planning, or manifest logic. It may only:
1. discover/display state via the controller's read operations, and
2. request preview/install through the same gated entry points (`Update-ArtCraftApp`,
   `Install-ApprovedUpdate`) with identical confirmation and binding rules.

No network, PowerShell execution, or installation code lives in the UI
project during Phase 2A (enforced by test).

## Top-bar specification (SUPPLIED — replaces all Phase 2A assumptions)

- Bar: `Surface` background, 1px `Border` bottom edge; content padding 24
  top/bottom, 28 sides; heading block left, buttons right, both bottom-aligned.
- Left: heading `Updates`, 24px, weight 700, `#E7E9EE`, no margin; subheader
  14px regular `#9AA1AE`, 4px below; default text `1 update available ·
  last checked today at 22:11`; up-to-date, `Checking for updates...`, and
  amber-toned failure variants.
- Right, 10px gaps: `Check again` (secondary, 16px refresh icon, 8px icon
  gap), `Update selected` (secondary), `Update all` (primary). All buttons:
  40px tall, 8px radius, 1px border, 18px padding, Segoe UI 14px semibold.
- Secondary `#232730`/`#343945`/`#E7E9EE`; hover `#2A2F3A`/`#3F4552`;
  pressed `#1D2027`/`#343945`; focus 2px `#6AA5FF` +2px offset; disabled
  `#1A1D23`/`#272B34`/`#5B6270`, hover-inert via IsEnabled-gated triggers.
- Primary `#6AA5FF`/`#0B1220`; hover `#85B6FF`; pressed `#4F90F0`; focus 2px
  `#E7E9EE` +2px; disabled `#26324A`/`#6F7A90`.
- Checking: `Checking...` label + spinner, all three buttons disabled.
  `Update selected` off without selection; `Update all` off without updates.

## Tokens (Dark.xaml, the only theme until a light variant is specified)

Window `#0F1115`, title bar `#14171C`/`#22262E`, surface `#181B21`, border
`#272B34`, selected row `#1C2230`, text `#E7E9EE`/`#C5CAD3`/muted `#9AA1AE`,
accent `#6AA5FF` on `#0B1220`, success `#6EE0A8` on `#16301F`, warning
`#F5C26B` on `#3A2D12`, window border `#2A2E37`, card radius 12, button
radius 8, Segoe UI throughout (system fonts only, no licensed files).

## Known deviations from the spec

- Window radius/chrome: system window kept (custom chrome deferred as
  drag/resize work disproportionate to a prototype).
- The removed `Light.xaml` assumptions from Phase 2A are void.
- "Title bar" tokens exist for future custom chrome; the OS draws the bar.

## Phased migration (from audit)

2A top bar (this phase) -> app list components -> live integration ->
update flow -> one-click/Update All -> a11y/l10n/themes polish ->
regression + packaging. Engine untouched throughout.
