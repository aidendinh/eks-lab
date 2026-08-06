variable "git_repository_url" {
  description = "Repository Argo CD syncs the microservices chart from. Must be reachable from the cluster and must contain the commit you expect."
  type        = string
  default     = "https://github.com/aidendinh/eks-lab.git"
}

variable "git_target_revision" {
  description = "Git revision Argo CD tracks."
  type        = string
  default     = "HEAD"
}

variable "collector_image_tag" {
  description = "Tag of the JavaMelody collector image in the lab ECR repository."
  type        = string
  default     = "javamelody-collector-2.8.0"
}
