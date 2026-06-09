output "public_ip" {
  description = "Elastic IP – point your DNS A record (recite-ayah.quranlingo.app) here before running init-ssl.sh"
  value       = aws_eip.main.public_ip
}

output "ssh_command" {
  description = "SSH into the instance"
  value       = "ssh ubuntu@${aws_eip.main.public_ip}"
}

output "ami_used" {
  description = "Deep Learning AMI automatically selected"
  value       = "${data.aws_ami.deep_learning.name} (${data.aws_ami.deep_learning.id})"
}

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT

    1. Point DNS:  recite-ayah.quranlingo.app  →  A  ${aws_eip.main.public_ip}
    2. Wait for DNS propagation (~5 min for most registrars)
    3. SSH in and set up HTTPS:
         ssh ubuntu@${aws_eip.main.public_ip}
         /app/deploy/scripts/init-ssl.sh your@email.com
    4. Add GitHub Secrets for CI/CD:
         EC2_HOST = ${aws_eip.main.public_ip}
         EC2_SSH_KEY = <private key matching the public key in terraform.tfvars>
  EOT
}
