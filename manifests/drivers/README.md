# Driver Manifests

Driver manifests describe how Agent OS reads organ-specific evidence without
hard-coding every organ implementation into the runtime core.

They define generic observation mechanisms, organ-specific driver composition,
capability evidence contracts, event sources, topology outputs, and safety
limits.

The manifest is not the live status. It is the contract used by collectors and
viewers to know which driver should be asked for which kind of evidence.

## Files

- `standard.json`: first driver set for the current standard
  migration baseline.

## Update Model

The driver manifest changes when an organ integration surface changes:

- new organ or organ service
- new health endpoint or event outbox
- changed capability evidence contract
- changed safety or approval boundary

Live topology and current capability state are generated snapshots. They should
not be manually edited into this manifest.
