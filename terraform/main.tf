resource "aws_s3_bucket" "my_bucket" {
  bucket = "my-bucket1234556789098766"
}

resource "aws_iam_role" "lambda_role" {
name   = "Transform_Lambda_Function_Role"
assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "lambda.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}

resource "aws_iam_policy" "iam_policy_for_lambda" {
 name         = "aws_iam_policy_for_terraform_aws_lambda_role"
 path         = "/"
 description  = "AWS IAM Policy for managing aws lambda role"
 policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": [
       "logs:*"
     ],
     "Resource": "arn:aws:logs:*:*:*",
     "Effect": "Allow"
   },
    {
        "Effect": "Allow",
        "Action": [
            "s3:*"
        ],
        "Resource": "arn:aws:s3:::*"
    }
 ]
}
EOF
}
 
resource "aws_iam_role_policy_attachment" "attach_iam_policy_to_iam_role" {
 role        = aws_iam_role.lambda_role.name
 policy_arn  = aws_iam_policy.iam_policy_for_lambda.arn
}
 
data "archive_file" "transform_zip" {
  type        = "zip"
  source_dir  = "../transform/"
  output_path = "../transform/transform-${timestamp()}.zip"
}
 
resource "aws_lambda_function" "terraform_lambda_func" {
  filename                       = data.archive_file.transform_zip.output_path
#  s3_bucket                      = aws_s3_bucket.my_bucket
  function_name                  = "Transform_Lambda_Function"
  role                           = aws_iam_role.lambda_role.arn
  handler                        = "main.lambda_handler"
  runtime                        = "python3.8"
  depends_on                     = [
    aws_iam_role_policy_attachment.attach_iam_policy_to_iam_role,
    data.archive_file.transform_zip,
    aws_efs_mount_target.alpha
  ]

  vpc_config {
    subnet_ids         = [module.vpc.intra_subnets[0]]
    security_group_ids = [module.vpc.default_security_group_id]
  }
#  attach_network_policy  = true

  file_system_config {
    arn = aws_efs_access_point.lambda.arn
    local_mount_path = "/mnt/files"
  }
}

resource "aws_sns_topic" "topic" {
  name = "s3-event-notification-topic"

  policy = <<POLICY
{
    "Version":"2012-10-17",
    "Statement":[{
        "Effect": "Allow",
        "Principal": { "Service": "s3.amazonaws.com" },
        "Action": "SNS:Publish",
        "Resource": "arn:aws:sns:*:*:s3-event-notification-topic",
        "Condition":{
            "ArnLike":{"aws:SourceArn":"${aws_s3_bucket.my_bucket.arn}"}
        }
    }]
}
POLICY
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.my_bucket.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.terraform_lambda_func.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_bucket]
}

resource "aws_lambda_permission" "allow_bucket" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.terraform_lambda_func.function_name
  principal = "s3.amazonaws.com"
  source_arn = "arn:aws:s3:::${aws_s3_bucket.my_bucket.id}"
}

######
# SQS
######

resource "aws_sqs_queue" "output_queue" {
  name                      = "output-queue"
  delay_seconds             = 90
  max_message_size          = 2048
  message_retention_seconds = 86400
  receive_wait_time_seconds = 10
}

resource "aws_iam_role_policy_attachment" "lambda_sqs_role_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

resource "aws_iam_role_policy_attachment" "iam_role_policy_attachment_lambda_vpc_access_execution" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

######
# VPC
######

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name = "vpc_name"
  cidr = "10.10.0.0/16"

  azs           = ["eu-central-1a"]
  intra_subnets = ["10.10.101.0/24"]
}

######
# EFS
######

resource "aws_efs_file_system" "shared" {}

resource "aws_efs_mount_target" "alpha" {
  file_system_id  = aws_efs_file_system.shared.id
  subnet_id       = module.vpc.intra_subnets[0]
  security_groups = [module.vpc.default_security_group_id]
}

resource "aws_efs_access_point" "lambda" {
  file_system_id = aws_efs_file_system.shared.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/lambda"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "0777"
    }
  }
}