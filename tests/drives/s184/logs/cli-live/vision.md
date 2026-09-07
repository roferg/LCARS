# Project vision

_Written by Establish Vision (`lcars` / the viewscreen front door). This
file is the durable record of what this project is FOR. The initialization
mission below builds only the foundation; everything under DEFERRED becomes
a normal LCARS mission once that foundation lands._

## What the captain asked for

a website that does personal finance stuff. Basically a Mint clone — budgets,
charts, bank sync via Plaid, a mobile app, CSV import from my bank,
recurring-bill detection, multi-currency and a shared household mode. I need it
shipped by Friday. Also a dark mode toggle, a Chrome extension and email
digests. Just plan the whole feature list now.

## Stack (accepted)

**Vite + React + Vitest**

### Why

- It's a website for personal finance stuff, and this gets a React web app booting fast
- You want charts and budgets that feel snappy in the browser — Vite gives instant feedback while building
- Vitest is wired in from the start so the test system is real and watchable, not bolted on later
- One familiar JavaScript stack keeps the door open for the mobile app and Chrome extension you named, without deciding them now

## Foundation — the initialization mission

- A running skeleton.
- A working test system for Vite + React + Vitest.
- One thin vertical slice: importing one CSV row from your bank and showing it on screen

## DEFERRED — features, recorded here, NOT in the initialization mission

- Budgets
- Charts
- Bank sync via Plaid
- Mobile app
- CSV import from bank (full feature)
- Recurring-bill detection
- Multi-currency
- Shared household mode
- Dark mode toggle
- Chrome extension
- Email digests

_Each of these becomes its own `lcars file` mission once the foundation lands._
