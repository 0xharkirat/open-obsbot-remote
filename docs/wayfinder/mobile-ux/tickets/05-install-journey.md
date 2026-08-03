# Decide the install journey

`wayfinder:grilling` - HITL - status: **open, blocked**

Blocked by: [What installable costs, and whether a service worker can be safe here](01-installable-without-cache-poisoning.md)

## Question

How does the app get onto a phone's home screen, who is asked, when, and what happens to everyone who never does it?

## Why it is blocked

The research ticket may come back saying installability is not achievable on a plain-HTTP LAN origin, or that it costs a service worker whose risk is unacceptable given the icon-cache history. Either answer redraws this ticket, so deciding the journey first would be deciding in the dark.

## What has to be decided, assuming it is achievable

- **When the prompt appears.** Not on first load, because the operator came to work. Probably after a first successful session, when the app has earned it.
- **How iOS is handled.** Add to Home Screen lives in the share sheet and cannot be triggered by the page, so the app has to teach a gesture rather than offer a button. That is a genuine instructional design problem and the hardest part of this ticket.
- **What the installed app does differently.** More vertical space, no pull-to-refresh, no accidental tab close. Whether the design assumes standalone and degrades in a tab, or targets the tab and improves in standalone.
- **How an installed copy updates.** The version now shows in the footer, which makes a stale build visible. Whether the app can tell the operator a newer build is being served and offer to reload.
- **What happens to people who never install.** A shared or borrowed phone should not be nagged. The tab experience has to stay first class.
- **Whether the bridge should help.** It is showing a QR to a person holding a phone, which is the ideal moment to say "add this to your home screen" on the Mac's screen rather than the phone's.

## Answer

_Unresolved._
