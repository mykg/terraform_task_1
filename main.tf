# configure the provider
provider "aws" {
  region = "ap-south-1"
  profile = "new_tf"
}

# creating a key pair
resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
resource "aws_key_pair" "generated_key" {
  key_name   = "deploy-key"
  public_key = tls_private_key.key.public_key_openssh
}

# saving key to local file
resource "local_file" "deploy-key" {
    content  = tls_private_key.key.private_key_pem
    filename = "/root/terra/task1/deploy-key.pem"
}

# creating a SG
resource "aws_security_group" "allow_ssh_http" {
  name        = "allow_ssh_http"
  description = "Allow ssh and http inbound traffic"
  
  ingress {
    description = "ssh"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "http"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_ssh_http"
  }
}


# launching an ec2 instance
resource "aws_instance" "myin" {
  ami  = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = aws_key_pair.generated_key.key_name
  security_groups = [ "allow_ssh_http" ]
  
  depends_on = [
    null_resource.nulllocal2,
  ]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = file("/root/terra/task1/deploy-key.pem")
    host     = aws_instance.myin.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install httpd  php git -y",
      "sudo systemctl restart httpd",
      "sudo systemctl enable httpd",
    ]
  }

  tags = {
    Name = "os1"
  }
}

# create an ebs volume
resource "aws_ebs_volume" "ebstest" {
  availability_zone = aws_instance.myin.availability_zone
  size              = 1
  tags = {
    Name = "ebs1"
  }
}

# create an ebs snapshot
resource "aws_ebs_snapshot" "ebstest_snapshot" {
  volume_id = aws_ebs_volume.ebstest.id
  tags = {
    Name = "ebs1_snap"
  }
}

# attaching the volume
resource "aws_volume_attachment" "ebs1_att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ebstest.id
  instance_id = aws_instance.myin.id
  force_detach = true
}

resource "null_resource" "nullremote1"  {
  depends_on = [
    aws_volume_attachment.ebs1_att,
    aws_s3_bucket_object.object
  ]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = file("/root/terra/task1/deploy-key.pem")
    host     = aws_instance.myin.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mkfs.ext4  /dev/xvdh",
      "sudo mount  /dev/xvdh  /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/mykg/sampleCloud.git /var/www/html"
    ]
  }
}

# setting read_permission on pem
resource "null_resource" "nulllocal2"  {
  depends_on = [
    local_file.deploy-key,
  ]
   provisioner "local-exec" {
            command = "chmod 400 /root/terra/task1/deploy-key.pem"
        }
}

################## cloud front and s3 ##################
resource "aws_s3_bucket" "b" {
  bucket = "mynkbucket19"
  acl    = "public-read"

  tags = {
    Name        = "mynkbucket"
  }
}

resource "aws_s3_bucket_object" "object" {
  depends_on = [ aws_s3_bucket.b, ]
  bucket = "mynkbucket19"
  key    = "x.jpg"
  source = "/root/terra/task1/cloudfront/x.jpg"
  acl = "public-read"
}


locals {
  s3_origin_id = "S3-mynkbucket19"
}

# origin access id
resource "aws_cloudfront_origin_access_identity" "oai" {
  comment = "this is OAI to be used in cloudfront"
}

# creating cloudfront 
resource "aws_cloudfront_distribution" "s3_distribution" {

  depends_on = [ aws_cloudfront_origin_access_identity.oai, 
                 null_resource.nullremote1,  
  ]

  origin {
    domain_name = aws_s3_bucket.b.bucket_domain_name
    origin_id   = local.s3_origin_id

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.oai.cloudfront_access_identity_path
    }
  }

    connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = file("/root/terra/task1/deploy-key.pem")
    host     = aws_instance.myin.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo su << EOF",
      "echo \"<img src='http://${self.domain_name}/${aws_s3_bucket_object.object.key}'>\" >> /var/www/html/index.html",
      "EOF"
    ]
  }


  enabled             = true
  is_ipv6_enabled     = true

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    viewer_protocol_policy = "redirect-to-https"
  }

  
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}


# IP
output "IP_of_inst" {
  value = aws_instance.myin.public_ip
}
