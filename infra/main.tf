resource "aws_s3_bucket" "static_site" {
  bucket = var.bucket_name

  tags = {
    Environment = "var.environment"
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket_public_access_block" "static_site" {
  bucket = aws_s3_bucket.static_site.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "static_site" {
  bucket = aws_s3_bucket.static_site.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

data "aws_iam_policy_document" "static_site_public_read" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["${aws_s3_bucket.static_site.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "static_site" {
  bucket     = aws_s3_bucket.static_site.id
  depends_on = [aws_s3_bucket_public_access_block.static_site]

  policy = data.aws_iam_policy_document.static_site_public_read.json
}