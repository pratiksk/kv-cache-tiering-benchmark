output "instance_id" {
  value = aws_instance.node.id
}

output "ami_name" {
  value = data.aws_ami.dlami.name
}

output "availability_zone" {
  value = aws_subnet.public.availability_zone
}

output "results_uri" {
  value = "s3://${var.state_bucket}/${var.project}/results/"
}
