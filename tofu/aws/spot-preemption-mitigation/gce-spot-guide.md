# Google Compute Engine (GCE) — Spot VM Implementation Guide

GCE provides **Spot VMs** (which replaced the older 24-hour limited Preemptible VMs).

## Mitigation Hook

Watch for the `computeEngine/v1/instance/preempted` metadata key. GCE also sends a standard **ACPI PowerButton** signal to the OS.

## Best Practice

Set your `shutdown-script` in the instance metadata. When the 30-second ACPI signal hits, the OS automatically runs this script to push logs, save tokens, or drain container workloads before termination.
