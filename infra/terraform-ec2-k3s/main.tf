# Latest Ubuntu 22.04 LTS AMI, resolved via AWS's own SSM parameter rather
# than a hardcoded/copy-pasted AMI ID — those are region- and
# time-specific and go stale. Ubuntu over Amazon Linux here purely because
# k3s's own docs and community troubleshooting content skew Ubuntu/Debian;
# either works.
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

resource "aws_instance" "k3s" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  key_name               = aws_key_pair.k3s.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k3s.id]

  associate_public_ip_address = true

  # Off by default now that instance_type defaults to a Free Tier–eligible
  # type (see variables.tf's use_spot comment — Free Tier hours only cover
  # on-demand usage, so requesting Spot on top of an eligible type would
  # just mean paying Spot prices instead of using the free hours). Set
  # use_spot = true if you're on a non-eligible instance_type, or once
  # your account's Free Tier window has ended — Spot is typically 60-80%
  # off on-demand for a box you run a few hours a day and destroy.
  #
  # instance_interruption_behavior = "terminate" (not "stop"/"hibernate")
  # is deliberate when Spot is on: this box is already ephemeral by design
  # (up.sh/down.sh apply+destroy it fresh each session, see the README),
  # so there's nothing worth preserving across an AWS-initiated
  # interruption either — terminate is the simplest behavior and the only
  # one that doesn't require extra EBS/hibernation configuration.
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        instance_interruption_behavior = "terminate"
        spot_instance_type             = "one-time"
        max_price                      = var.spot_max_price
      }
    }
  }

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Runs once at first boot. Since this instance is always freshly created
  # (never stopped/restarted — see the spot behavior note above), "runs
  # once at first boot" and "runs every time you start using this" are the
  # same thing here, which is exactly what makes cloud-init the right tool
  # instead of a systemd unit that would need to handle re-runs.
  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    repo_url = var.repo_url
    repo_ref = var.repo_ref
  })

  # Forces a clean replace (new instance, new user_data run) if you change
  # repo_url/repo_ref between sessions, instead of leaving a stale clone on
  # an instance that Terraform would otherwise consider unchanged.
  user_data_replace_on_change = true

  tags = {
    Name = var.name_prefix
  }
}
