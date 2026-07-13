# Oracle Cloud Infrastructure (OCI) — Preemptible Instances Implementation Guide

OCI offers **Preemptible Instances** across both AMD/Intel x86 and Ampere ARM shapes.

## Mitigation Hook

Poll the metadata endpoint `http://169.254.169`. When preemption is triggered, this endpoint returns a JSON payload detailing the termination schedule.

## Best Practice

Because OCI deletes the boot volume upon preemption (**TERMINATE only**), you must use a detached block volume or network share for persistent state storage. Never save application progress directly to the local boot drive.
