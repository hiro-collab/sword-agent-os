# Platform Profiles

Platform profiles describe where a runtime profile is expected to start.

They are intentionally separate from `manifests/profiles/`. Runtime profiles
describe what the system expects. Platform profiles describe which environment
starts those expectations, and which optional lanes stay off by default.

Current draft profiles:

- `windows-demo.json`: keeps the existing Windows demo shape available.
- `linux-headless.json`: defines the small no-device startup target.

These are source/static planning manifests. They do not prove runtime behavior,
Linux support, WSL support, ROS support, Home Control operation, camera access,
audio access, or physical-device behavior by themselves.
