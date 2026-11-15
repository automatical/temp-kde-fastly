variable "s3_endpoint" {
    description = "Hostname of the S3-compatible endpoint, e.g. s3.example.org (no scheme)."
    type        = string
}

variable "s3_bucket_name" {
    description = "Bucket that receives discuss.kde.org access logs."
    type        = string
}

variable "s3_access_key" {
    description = "Access key for the S3-compatible endpoint."
    type        = string
    sensitive   = true
}

variable "s3_secret_key" {
    description = "Secret key for the S3-compatible endpoint."
    type        = string
    sensitive   = true
}

variable "s3_path" {
    description = "Object key prefix for log files. Must end with a trailing slash; strftime tokens are allowed."
    type        = string
    default     = "/discuss.kde.org/%Y/%m/%d/"
}

variable "log_period" {
    description = "How often (seconds) Fastly uploads a log file."
    type        = number
    default     = 300
}
