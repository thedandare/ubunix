## **Spot preemption mitigation** 

|the practice of designing cloud architectures to handle unexpected terminations of discounted, excess-capacity compute resources (Spot VMs). By using fault-tolerant patterns like checkpointing, task queues, and auto-scaling, engineers capture 60%–91% cost savings without sacrificing system reliability.

1. Leverage Cloud-Native Interruption Signals

-   Google Cloud: The system sends a signal to the VM's metadata, triggering a defined termination action like "Stop" (retains local disk data) or "Delete".[cf](https://cloud.google.com/blog/topics/cost-management/rethinking-your-vm-strategy-spot-vms)
- AWS & Azure: Services use the Instance Metadata Service (IMDS) to publish impending "preempt" or "interruption" events.
 [cf](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html)

 ### Action:
  Configure a daemon to poll the metadata API and immediately execute a graceful shutdown script (e.g., saving progress to an object store) before the power is cut.

  2. Design for Idempotency & Checkpointing

- **Idempotent Operations**: Design tasks so that running them multiple times yields the same result. If a Spot job is preempted and restarted, it won't duplicate data or corrupt your database.

- **Checkpointing**: Routinely save processing states or model weights to cloud storage (e.g., Amazon S3 or Google Cloud Storage). When a new node is spun up, it resumes from the latest checkpoint rather than starting from scratch.

3. Implement Instance & Task Queues

- **Task Queues**: Use decoupled messaging services like AWS SQS or Google Cloud Pub/Sub. If a worker node goes offline, the unacknowledged message simply returns to the queue to be picked up by a new instance.

- **Auto-Scaling**: Integrate with managed services like AWS Karpenter or Google Kubernetes Engine (GKE) Autoscalers to instantly provision replacement nodes when preemptions occur.

4. Diversify & Decouple

Avoid relying on a single, congested configuration.

- **Mixed Instance Types**: Utilize instance flexibility. Instead of requesting only one specific machine size, allow the auto-scaler to spin up various similar machine types.

- **Multi-AZ/Multi-Region**: Spread your Spot workloads across multiple Availability Zones to minimize the blast radius of localized capacity shortages.

- **On-Demand Fallback**: Configure your scaling groups to seamlessly default to standard On-Demand instances if Spot capacity is temporarily depleted


## Comparison of Spot Mechanics

| Feature | Google Compute Engine (GCE) | AWS EC2 Spot Instances | OCI Preemptible Instances |
|---|---|---|---|
| **Interruption Notice** | 30-second warning | 2-minute warning | 30-second warning |
| **Notice Location** | Metadata server / ACPI signal | Instance Metadata Service (IMDS) | Metadata service (`/instance/action`) |
| **Eviction Action** | STOP (save state) or DELETE | terminate, stop, or hibernate | TERMINATE only |
| **Pricing Model** | Fixed up to 60–91% off On-Demand | Dynamic based on real-time supply | Fixed up to 50% off On-Demand |

## Implementation Guide by Provider

- [Google Compute Engine (GCE)](gce-spot-guide.md)
- [AWS Amazon EC2 Spot](aws-spot-guide.md)
- [Oracle Cloud Infrastructure (OCI)](oci-spot-guide.md)

