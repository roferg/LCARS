# Project vision

_Written by Establish Vision (`lcars` / the viewscreen front door). This
file is the durable record of what this project is FOR. The initialization
mission below builds only the foundation; everything under DEFERRED becomes
a normal LCARS mission once that foundation lands._

## What the captain asked for

Build me a Mint clone with budgets, charts, bank sync via Plaid, a mobile app, CSV import, recurring-bill detection, multi-currency and a shared household mode. Ship by Friday. Also: a dark mode toggle, a Chrome extension, and email digests.

## Stack (accepted)

**Vite + React + Vitest**

### Why

- You said budgets and charts — React has the chart libraries.
- Vitest is fast so red-then-green stays quick.

## Foundation — the initialization mission

- A running skeleton.
- A working test system for Vite + React + Vitest.
- One thin vertical slice: importing a CSV row and showing it

## DEFERRED — features, recorded here, NOT in the initialization mission

- Budgets
- Charts
- Bank sync via Plaid
- Mobile app
- Recurring-bill detection
- Multi-currency
- Shared household mode
- Dark mode toggle
- Chrome extension
- Email digests
- Ship by Friday

_Each of these becomes its own `lcars file` mission once the foundation lands._
