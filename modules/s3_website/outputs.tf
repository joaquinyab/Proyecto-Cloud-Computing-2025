# URL completa del website (http)
output "website_url" {
  value = "http://${aws_s3_bucket.this.bucket}.s3-website-${var.region}.amazonaws.com"
}

# Hostname del website
output "website_hostname" {

  value = "${aws_s3_bucket.this.bucket}.s3-website-${var.region}.amazonaws.com"
}
