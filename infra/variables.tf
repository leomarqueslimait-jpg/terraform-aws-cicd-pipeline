variable "bucket_name" {
  description = "Name of the S3 bucket for the static site"
  type        = string
}

variable "environment" {
  description = "Enviroment name"
  type        = string
  default     = "dev"
}