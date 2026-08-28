###############################################################################
# CF-110 lab_env_student -- outputs.tf
#
# Hand these to the student at lab start. The CF-110 lab guides currently use
# placeholder identifiers (i-0abc123def456789, target-bucket, MyAppRole,
# SOURCE_ACCOUNT), so every command in them must be retargeted at these real
# values before a student can run anything verbatim.
###############################################################################

output "student_id" {
  description = "Student identifier this stack belongs to."
  value       = var.student_id
}

output "region" {
  description = "Region the stack is deployed in."
  value       = var.region
}

# -----------------------------------------------------------------------------
# Lab 1
# -----------------------------------------------------------------------------
output "lab1_instance_id" {
  description = "EC2 instance students investigate in Lab 1 Task 1."
  value       = aws_instance.lab1_target.id
}

output "lab1_lambda_function_name" {
  description = "Lambda with the injected timeout fault (Lab 1 Task 2)."
  value       = aws_lambda_function.slow.function_name
}

output "lab1_lambda_log_group" {
  description = "Log group holding the timeout evidence for the Lab 1 Task 2 Logs Insights queries."
  value       = aws_cloudwatch_log_group.lambda_slow.name
}

output "lab1_target_bucket" {
  description = "S3 bucket for Lab 1 Task 3. Replaces the 'target-bucket' placeholder in the guide."
  value       = aws_s3_bucket.lab1_target.id
}

output "lab1_cross_account_role_arn" {
  description = "Role that can ListBucket but not GetObject (Lab 1 Task 3). Replaces the CrossAccountRole placeholder."
  value       = aws_iam_role.cross_account.arn
}

output "lab1_burst_volume_id" {
  description = "gp2 volume carrying BurstBalance for Lab 1 Task 4. Replaces the 'vol-12345678' placeholder."
  value       = aws_ebs_volume.lab1_burst.id
}

# -----------------------------------------------------------------------------
# Lab 2
# -----------------------------------------------------------------------------
output "lab2_myapp_role_arn" {
  description = "Role denied s3:GetObject (Lab 2 Task 1). Replaces the MyAppRole placeholder."
  value       = aws_iam_role.myapp.arn
}

output "lab2_source_role_arn" {
  description = "Caller role for the Lab 2 Task 2 assumption attempt."
  value       = aws_iam_role.source_role.arn
}

output "lab2_target_role_arn" {
  description = "Role whose trust policy is wrong (Lab 2 Task 2). Assumption from SourceRole is denied."
  value       = aws_iam_role.target_role.arn
}


output "lab2_private_subnet_id" {
  description = "Private subnet with no 0.0.0.0/0 route. Replaces the 'subnet-private123' placeholder."
  value       = aws_subnet.private.id
}

output "lab2_nat_gateway_id" {
  description = "NAT gateway that exists and is healthy but is not routed to. Null when create_nat_gateway is false."
  value       = var.create_nat_gateway ? aws_nat_gateway.lab[0].id : null
}

output "lab2_alb_dns_name" {
  description = "ALB whose health checks fail (Lab 2 Task 4)."
  value       = aws_lb.lab.dns_name
}

output "lab2_target_group_arn" {
  description = "Target group reporting unhealthy. Replaces the placeholder target group ARN in the guide."
  value       = aws_lb_target_group.lab.arn
}


output "lab2_alb_sg_id" {
  description = "ALB security group. The target SG is missing an ingress rule referencing this group."
  value       = aws_security_group.alb.id
}

output "lab2_alb_target_sg_id" {
  description = "Target security group carrying the injected fault (Lab 2 Task 4). This is the app server's own SG -- there is one instance, and it is the ALB's only target."
  value       = aws_security_group.lab1_instance.id
}

output "vpc_flow_log_group" {
  description = "Flow log group for the Lab 2 Task 4 REJECT query."
  value       = aws_cloudwatch_log_group.flow_logs.name
}

# -----------------------------------------------------------------------------
# Student handout
# -----------------------------------------------------------------------------
output "student_handout" {
  description = "Everything a student needs, formatted for pasting into the lab handout."
  value       = <<-EOT
    CF-110 Lab Environment -- Student ${var.student_id}  (region ${var.region})

    LAB 1 -- Compute and Storage
      App server (all tasks) ${aws_instance.lab1_target.id}   cf110-${var.student_id}-app
      Lambda function ...... ${aws_lambda_function.slow.function_name}
      Lambda log group ..... ${aws_cloudwatch_log_group.lambda_slow.name}
      S3 target bucket ..... ${aws_s3_bucket.lab1_target.id}
      CrossAccountRole ..... ${aws_iam_role.cross_account.arn}
      gp2 burst volume ..... ${aws_ebs_volume.lab1_burst.id}

    LAB 2 -- IAM and Network
      MyAppRole ............ ${aws_iam_role.myapp.arn}
      SourceRole ........... ${aws_iam_role.source_role.arn}
      TargetRole ........... ${aws_iam_role.target_role.arn}
      Private subnet ....... ${aws_subnet.private.id}
      ALB DNS .............. ${aws_lb.lab.dns_name}
      Target group ......... ${aws_lb_target_group.lab.arn}
      Flow log group ....... ${aws_cloudwatch_log_group.flow_logs.name}
  EOT
}
