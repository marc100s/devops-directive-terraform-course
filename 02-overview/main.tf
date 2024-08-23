terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.63.1" #video, uses version 3 and AWS CLI v1; I suggest upgrading both to ensure credentials works, etc.
    }
  }
}

provider "aws" {
  region = "eu-west-3"
}

resource "aws_instance" "app_server" {
  ami           = "ami-09d83d8d719da9808" #ami for region, This case, Europe region
  instance_type = "t2.micro"
 
  tags = {
    Name = "ExampleAppServerInstance" #I suggest tagging, since it is better to get things more organized / named, despite it is being destroyed
  }
}
