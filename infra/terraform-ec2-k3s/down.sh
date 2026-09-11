#!/usr/bin/env bash
# Fully destroys the instance, its security group, and the generated
# keypair. Run this at the end of every session — see README.md for why
# "destroy" rather than "stop" is the right model here even on the
# Free Tier on-demand default: a stopped instance still holds its EBS
# volume (eating into the 30GB-month Free Tier storage allowance if you
# forget about it), and destroying keeps every session a clean rebuild
# from up.sh's user_data, same as the Spot path. If use_spot = true,
# there's a second reason — Spot capacity isn't guaranteed to survive a
# "stop" the way an on-demand instance's would; AWS may reclaim it
# anyway, so destroy is the only model that behaves the same either way.
set -euo pipefail
cd "$(dirname "$0")"
terraform destroy -auto-approve
