output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR, used to scope the EFS security group ingress."
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet ids, in AZ order. Clusters, nodes and EFS mount targets all live here."
  value       = [for az in var.azs : aws_subnet.private[az].id]
}

output "public_subnet_ids" {
  description = "Public subnet ids, in AZ order. NAT gateway and internet-facing NLBs only."
  value       = [for az in var.azs : aws_subnet.public[az].id]
}

output "private_subnets_by_az" {
  description = "AZ -> private subnet id, for resources that must be pinned to one zone."
  value       = { for az in var.azs : az => aws_subnet.private[az].id }
}
