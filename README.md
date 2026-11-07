# Delirium CarClaim

Build 42 mod for the Delirium server: vehicle claims. Requires **Delirium Economy** (and through it Delirium Shops). Replaces **VehicleClaimWG** and takes over its claims — switch VehicleClaimWG off when this one goes on.

- **Personal claims.** Right-click a vehicle: *Claim vehicle (n/max)*. Up to `MaxCars` per player. The owner can release the claim and give or remove access by account name.
- **Organization claims.** The head of an organization (or an admin) claims a vehicle for it: *Claim for an organization*. Up to `OrgMaxCars` per organization; they do not count against the head's own limit. The head and all staff of that organization use these vehicles; the head and admins manage them, and can give access to outsiders too (a passenger, a mechanic).
- **The claim lasts while the owner logs in**, like a safehouse: a personal claim ends when its owner has not been online for `InactivityDays` real days, an organization claim when neither its head nor any of its staff has. Driving the vehicle is not needed, there is no timer to refresh. Deleting an organization releases its vehicles.
- **Locked for everyone else**: getting in, the radial menu, the mechanics window, the trunk and seats, siphoning, towing — the vehicle's own context menu shows only who owns it. Admins have access to everything.
- **Lists.** *My vehicles* (world context menu, for those who have some), the *Vehicles* button in the organization window (head, staff, admins), and *All vehicle claims* for admins with days offline per claim. Access and the claim itself can be changed from the list without walking to the vehicle.
- **Taking over VehicleClaimWG.** On the first start the claims VehicleClaimWG saved are imported (those it was about to drop are skipped). When a vehicle is first loaded, the owner and access list stored on it by VehicleClaimWG win. Everybody's timer starts at the import.

Everything is done by the server: the claims are one global ModData table (`DelCarClaim_State`), the vehicle only carries its id (`DCC_ID`, or `WG_ID` from VehicleClaimWG). The server log and `Logs/<date>_DelCarClaim.txt` record every claim, release (with the reason), access change and window smashed on a claimed vehicle by someone without access.

## Sandbox options (page DelCarClaim)

| Option | Default | Meaning |
|---|---|---|
| `MaxCars` | 3 | personal vehicles per player |
| `OrgMaxCars` | 3 | vehicles per organization |
| `InactivityDays` | 14 | real days without logging in before a claim ends (0: never) |

## Development

`lua5.4 tools/sim.lua` from the repository root runs the server logic offline with stubbed game APIs (needs Delirium-Economy and Delirium-Shops checked out next to this repository).
