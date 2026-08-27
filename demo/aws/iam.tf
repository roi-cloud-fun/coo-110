###############################################################################
# CF-110 demo_environment -  iam.tf
#
# Chapter 3 (IAM and access) and Chapter 5 (S3 access) demo faults.
#
#   OrderFlowAppRole   can ListBucket, cannot GetObject  -> the AccessDenied
#   ReportingRole      permitted to call sts:AssumeRole   -> the caller
#   SettlementRole     trusts the WRONG principal         -> the denial
#
# The two IAM faults are deliberately different in kind. The first is a
# permissions gap on one identity. The second is a relationship failure that
# neither side reveals on its own -  the caller's policy is correct, and reading
# it alone leads nowhere. Demonstrating both back to back is what teaches the
# "read both halves" discipline.
###############################################################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Web tier role -  deliberately unremarkable, so it is not a red herring
# ---------------------------------------------------------------------------

resource "aws_iam_role" "web" {
  name               = "${local.name}-OrderFlowWebRole"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name}-OrderFlowWebRole" }
}

resource "aws_iam_role_policy_attachment" "web_ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "web" {
  name = "${local.name}-web-profile"
  role = aws_iam_role.web.name
}

# ---------------------------------------------------------------------------
# CHAPTER 3 / 5 DEMO FAULT -  app role may list the bucket but not read it
# ---------------------------------------------------------------------------
# s3:GetObject is deliberately absent. `aws s3 ls` succeeds while `aws s3 cp`
# returns AccessDenied, and the Policy Simulator reports:
#
#   s3:ListBucket  -> allowed        (against the BUCKET arn)
#   s3:GetObject   -> implicitDeny   (against the OBJECT arn)
#
# implicitDeny, not explicitDeny: no policy ever granted the action, so adding
# an Allow fixes it. An explicit Deny would need finding and removing instead,
# and the simulator is how you tell those apart before attempting a fix.
resource "aws_iam_role" "app" {
  name               = "${local.name}-OrderFlowAppRole"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name}-OrderFlowAppRole" }
}

resource "aws_iam_role_policy" "app_s3" {
  name = "OrdersListOnly"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ListBucketButNotRead"
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = aws_s3_bucket.orders.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-app-profile"
  role = aws_iam_role.app.name
}

# ---------------------------------------------------------------------------
# CHAPTER 3 DEMO FAULT -  role assumption denied by the TARGET
# ---------------------------------------------------------------------------

resource "aws_iam_role" "reporting" {
  name               = "${local.name}-ReportingRole"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name}-ReportingRole" }
}

resource "aws_iam_role_policy" "reporting_can_assume" {
  name = "AllowAssumeSettlement"
  role = aws_iam_role.reporting.id
  # The caller IS permitted to try. This half is correct, and reading only this
  # half is what sends engineers looking in the wrong place for an hour.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowAssumeSettlementRole"
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = aws_iam_role.settlement.arn
    }]
  })
}

# INJECTED FAULT: SettlementRole's trust policy names the WEB role, not
# ReportingRole. An AssumeRole call from ReportingRole therefore returns
# AccessDenied, and the fix is a one-line trust policy correction.
#
# Note this produces the same AccessDenied text as the permissions-gap fault
# above. Telling them apart is the skill.
data "aws_iam_policy_document" "settlement_trust_broken" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.web.arn]
    }
  }
}

resource "aws_iam_role" "settlement" {
  name               = "${local.name}-SettlementRole"
  assume_role_policy = data.aws_iam_policy_document.settlement_trust_broken.json
  tags               = { Name = "${local.name}-SettlementRole" }
}

resource "aws_iam_role_policy" "settlement_read" {
  name = "OrdersFullRead"
  role = aws_iam_role.settlement.id
  # This role has exactly the permissions the app is missing. Once the trust
  # policy is corrected, assuming it is a legitimate route to the data -  which
  # makes the fault worth fixing rather than an arbitrary puzzle.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.orders.arn, "${aws_s3_bucket.orders.arn}/*"]
    }]
  })
}
