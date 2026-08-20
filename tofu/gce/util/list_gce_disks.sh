#!/bin/sh
sudo gcloud compute disks list --project project-1ab07399-29ab-4352-8f8 --format="table(name,zone,sizeGb,type)" 

# sudo gcloud compute disks delete gcnix santnix0 --zone southamerica-west1-b --project project-1ab07399-29ab-4352-8f8 --quiet

