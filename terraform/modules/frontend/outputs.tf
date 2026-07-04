output "bucket_name" {
  description = "Name of the S3 bucket holding the built frontend assets"
  value       = aws_s3_bucket.frontend.bucket
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — needed for cache invalidation after a deploy"
  value       = aws_cloudfront_distribution.frontend.id
}

output "cloudfront_domain_name" {
  description = "CloudFront's own *.cloudfront.net domain name"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "hostname" {
  description = "Public hostname the frontend is served on"
  value       = local.hostname
}
