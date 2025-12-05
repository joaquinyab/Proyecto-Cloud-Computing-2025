########################################
#  S3 Website Hosting con nombre único #
########################################

# Sufijo único (6 caracteres hex)
resource "random_id" "bucket" {
  byte_length = 3
}

locals {
  normalized_input = lower(replace(trimspace(var.website_bucket_name), "_", "-"))
  generated_name   = lower(replace("${var.project}-web-${random_id.bucket.hex}", "_", "-"))

  bucket_name = element(
    compact([
      local.normalized_input,
      local.generated_name
    ]),
    0
  )
}

########################################
#  BUCKET
########################################
resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = true
  tags          = merge(var.tags, { Name = local.bucket_name })
}

########################################
#  WEBSITE CONFIG
########################################
resource "aws_s3_bucket_website_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  index_document { suffix = "login.html" }
  error_document { key = "login.html" }
}

########################################
#  PÚBLICO (solo lectura de objetos)
########################################
resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "public" {
  statement {
    sid       = "PublicReadGet"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${aws_s3_bucket.this.id}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "public" {
  bucket     = aws_s3_bucket.this.id
  policy     = data.aws_iam_policy_document.public.json
  depends_on = [aws_s3_bucket_public_access_block.this]
}

########################################
#  HTML + JS (inyectado por Terraform)
########################################
resource "aws_s3_object" "login" {
  bucket       = aws_s3_bucket.this.id
  key          = "login.html"
  content      = join("", [file(var.login_file_path), "\n<script>\n", var.login_inline_js, "\n</script>\n"])
  content_type = "text/html"

  depends_on = [
    aws_s3_bucket_public_access_block.this,
    aws_s3_bucket_policy.public
  ]
}

resource "aws_s3_object" "app" {
  bucket       = aws_s3_bucket.this.id
  key          = "app.html"
  content      = join("", [file(var.app_file_path), "\n<script>\n", var.app_inline_js, "\n</script>\n"])
  content_type = "text/html"

  depends_on = [
    aws_s3_bucket_public_access_block.this,
    aws_s3_bucket_policy.public
  ]
}

