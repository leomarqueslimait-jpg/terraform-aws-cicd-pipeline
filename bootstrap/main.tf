#OIDC Provider
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com" #who is issuing the token

  client_id_list = ["sts.amazonaws.com"] #who is receiving the token

  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub" #only allows if the subject of this token matches my repo
      values   = ["repo:leomarqueslimait-jpg/terraform-aws-cicd-pipeline:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud" #only allows if the audience of this token matches AWS STS services
      values   = ["sts.amazonaws.com"]
    }

  }
}

data "aws_iam_policy_document" "git_hub_actions_s3" {
  statement {
    effect  = "Allow"
    actions = ["s3: *"]
    resources = ["arn::aws:s3:::cicd-pipeline/terraform.tfstate",
      "arn::aws:s3:::cicd-pipeline/terraform.tfstate/*",
      "arn:aws:s3:::projects-tf-state-new",
      "arn:aws:s3:::projects-tf-state-new/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]

    resources = ["arn:aws:dynamodb:us-east-1:*:table/tf-state-lock"]
  }

}

resource "aws_iam_role" "github_actions" {
  name = "github-actions-terraform-role"

  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

resource "aws_iam_policy" "git_hub_actions_s3" {
  name   = "github-actions-s3-policy"
  policy = data.aws_iam_policy_document.git_hub_actions_s3.json
}

resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.git_hub_actions_s3.arn
}