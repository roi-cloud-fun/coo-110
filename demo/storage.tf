###############################################################################
# CF-110 demo_environment -  storage.tf
#
# The OrderFlow orders bucket. Chapter 5's S3 AccessDenied demo runs against
# this, and CloudTrail data events are enabled on it (see observability.tf) so
# the denied GetObject call is actually visible in CloudTrail -  which is what
# makes the Chapter 3 and Chapter 5 CloudTrail demos work at all.
###############################################################################

resource "random_string" "bucket_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_s3_bucket" "orders" {
  bucket        = "${local.name}-orders-${random_string.bucket_suffix.result}"
  force_destroy = true
  tags          = { Name = "${local.name}-orders-bucket" }
}

resource "aws_s3_bucket_public_access_block" "orders" {
  bucket                  = aws_s3_bucket.orders.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "orders" {
  bucket = aws_s3_bucket.orders.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "orders" {
  bucket = aws_s3_bucket.orders.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Fixture objects. The demo lists these successfully and then fails to read
# one -  that asymmetry is the entire Chapter 5 diagnosis.
resource "aws_s3_object" "orders_data" {
  for_each = {
    "orders/2026-08-26-orders.csv"   = "order_id,region,amount,status\n881204,us-east,412.00,settled\n881205,eu-west,89.50,pending\n881206,us-west,1204.75,settled\n"
    "orders/README.txt"              = "OrderFlow order exports. CF-110 demo environment.\n"
    "settlements/daily-summary.json" = "{\"date\":\"2026-08-26\",\"settled\":2,\"pending\":1,\"total\":1706.25}\n"
  }
  bucket       = aws_s3_bucket.orders.id
  key          = each.key
  content      = each.value
  content_type = "text/plain"
}
