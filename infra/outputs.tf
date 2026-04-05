output "website_url" {
  description = "URL of the static website"
  value       = "http://${aws_s3_bucket_website_configuration.static_site.website_endpoint}"
}

output "bucket_name" {
  description = "Name of the static site bucket"
  value       = aws_s3_bucket.static_site.id
}