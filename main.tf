## Security group
resource "aws_security_group" "ssh_sg" {
  name        = "allow_ssh"
  description = "Allow SSH"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create Ansible Master
resource "aws_instance" "ansible_master" {
  ami                         = var.ami
  instance_type               = var.type
  key_name                    = var.key-name
  vpc_security_group_ids      = [aws_security_group.ssh_sg.id]
  associate_public_ip_address = true
  tags = {
    Name = "ansible-master"
  }

# Login to master and generate install ansible and generate public-private keys
  provisioner "remote-exec" {
    inline = [
      "sudo apt update -y",
      "sudo apt install -y openssh-server",
      "sudo apt install ansible -y",
      "ssh-keygen -t rsa -f /home/ubuntu/.ssh/id_rsa -q -N ''",
      "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("${var.key-name}.pem")
      host        = self.public_ip
    }
  }

# Get the public key from master to the local machine 
  provisioner "local-exec" {
    command = "ssh -o StrictHostKeyChecking=no -i kube.pem ubuntu@${self.public_ip} 'cat /home/ubuntu/.ssh/id_rsa.pub' > master_id_rsa.pub"
  }
}


# Create Ansible slaves 
resource "aws_instance" "ansible_slaves" {
  count                       = var.slaves
  ami                         = var.ami
  instance_type               = var.type
  key_name                    = var.key-name
  vpc_security_group_ids      = [aws_security_group.ssh_sg.id]
  associate_public_ip_address = true
  tags = {
    Name = "ansible-slave-${count.index + 1}"
  }

# Copy the public key of the master from local machine to /tmp folder of each slaves
  provisioner "file" {
    source      = "master_id_rsa.pub"
    destination = "/tmp/master_id_rsa.pub"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("${var.key-name}.pem")
      host        = self.public_ip
    }
  }

# Copy the keys from /tmp folder and add under .ssh/authorized keys file
  provisioner "remote-exec" {
    inline = [
      "mkdir -p ~/.ssh",
      "cat /tmp/master_id_rsa.pub >> ~/.ssh/authorized_keys",
      "chmod 600 ~/.ssh/authorized_keys"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("${var.key-name}.pem")
      host        = self.public_ip
    }
  }

  depends_on = [aws_instance.ansible_master]
}


# This block generates the inventory files
resource "null_resource" "generate_inventory_on_master" {
  depends_on = [
    aws_instance.ansible_master,
    aws_instance.ansible_slaves
  ]
  
  provisioner "local-exec" {
    command = "rm -rf master_id_rsa.pub"
  }

  provisioner "remote-exec" {
    inline = concat(
      [
        "echo '[master]' > inventory.ini",
        "hostname -I | awk '{print $1\" ansible_user=ubuntu ansible_ssh_common_args=\\\"-o StrictHostKeyChecking=no\\\"\"}' >> inventory.ini",
        "echo '' >> inventory.ini",
        "echo '[slaves]' >> inventory.ini"
      ],
      [
        for ip in aws_instance.ansible_slaves[*].private_ip :
        "echo '${ip} ansible_user=ubuntu ansible_ssh_common_args=\"-o StrictHostKeyChecking=no\"' >> inventory.ini"
      ],
      [
        "echo 'inventory.ini created on master:'",
        "cat inventory.ini"
      ]
    )

    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = aws_instance.ansible_master.public_ip
      private_key = file("${var.key-name}.pem")  
    }
  }
}
