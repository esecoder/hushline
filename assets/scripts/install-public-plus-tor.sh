#!/bin/bash

#Run as root
if [[ $EUID -ne 0 ]]; then
  echo "Script needs to run as root. Elevating permissions now."
  exec sudo /bin/bash "$0" "$@"
fi

# Welcome message and ASCII art
cat <<"EOF"
  _    _           _       _      _            
 | |  | |         | |     | |    (_)           
 | |__| |_   _ ___| |__   | |     _ _ __   ___ 
 |  __  | | | / __| '_ \  | |    | | '_ \ / _ \
 | |  | | |_| \__ \ | | | | |____| | | | |  __/
 |_|  |_|\__,_|___/_| |_| |______|_|_| |_|\___|
                                               
🤫 A self-hosted, anonymous tip line.

A free tool by Science & Design - https://scidsg.org
EOF
sleep 3

# Update and upgrade non-interactively
export DEBIAN_FRONTEND=noninteractive
apt update && apt -y dist-upgrade -o Dpkg::Options::="--force-confnew" && apt -y autoremove

# Install required packages
apt -y install whiptail curl git wget sudo

# Clone the repository in the user's home directory
cd $HOME
if [[ ! -d hushline ]]; then
    # If the hushline directory does not exist, clone the repository
    git clone https://github.com/scidsg/hushline.git
    cd hushline
    git switch hosted
else
    # If the hushline directory exists, clean the working directory and pull the latest changes
    echo "The directory 'hushline' already exists, updating repository..."
    cd hushline
    git switch hosted
    git restore --source=HEAD --staged --worktree -- .
    git reset HEAD -- .
    git clean -fd .
    git config pull.rebase false
    git pull
    cd $HOME # return to HOME for next steps
fi

# Install required packages
apt-get -y install git python3 python3-venv python3-pip certbot python3-certbot-nginx nginx tor unattended-upgrades gunicorn libssl-dev net-tools fail2ban ufw gnupg postgresql postgresql-contrib

# Function to display error message and exit
error_exit() {
    echo "An error occurred during installation. Please check the output above for more details."
    exit 1
}

# Trap any errors and call the error_exit function
trap error_exit ERR

# Prompt user for domain name
DOMAIN=$(whiptail --inputbox "Enter your domain name:" 8 60 3>&1 1>&2 2>&3)
DB_PASS=$(whiptail --inputbox "Enter your DB password:" 8 60 3>&1 1>&2 2>&3)

# PostgreSQL configuration
cd /tmp # Change to a directory accessible by all users
DB_EXISTS=$(sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -w hushlinedb)
if [ -z "$DB_EXISTS" ]; then
    sudo -u postgres psql -c "CREATE DATABASE hushlinedb;"
fi

USER_EXISTS=$(sudo -u postgres psql -c "\du" | cut -d \| -f 1 | grep -w hushlineuser)
if [ -z "$USER_EXISTS" ]; then
    sudo -u postgres psql -c "CREATE USER hushlineuser WITH PASSWORD '$DB_PASS';"
fi

sudo -u postgres psql -c "CREATE DATABASE hushlinedb;"
sudo -u postgres psql -c "CREATE USER hushlineuser WITH PASSWORD '$DB_PASS';"
sudo -u postgres psql -c "ALTER ROLE hushlineuser SET client_encoding TO 'utf8';"
sudo -u postgres psql -c "ALTER ROLE hushlineuser SET default_transaction_isolation TO 'read committed';"
sudo -u postgres psql -c "ALTER ROLE hushlineuser SET timezone TO 'UTC';"
sudo -u postgres psql -c "GRANT CONNECT ON DATABASE hushlinedb TO hushlineuser;"
sudo -u postgres psql -c "GRANT USAGE ON SCHEMA public TO hushlineuser;"
sudo -u postgres psql -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO hushlineuser;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO hushlineuser;"

cd - # Return to the previous directory

# Enter and test SMTP credentials
test_smtp_credentials() {
    python3 << END
import smtplib

def test_smtp_credentials(smtp_server, smtp_port, email, password):
    try:
        server = smtplib.SMTP_SSL(smtp_server, smtp_port)
        server.login(email, password)
        server.quit()
        return True
    except smtplib.SMTPException as e:
        print(f"SMTP Error: {e}")
        return False

if test_smtp_credentials("$NOTIFY_SMTP_SERVER", $NOTIFY_SMTP_PORT, "$EMAIL", "$NOTIFY_PASSWORD"):
    exit(0)  # Exit with status 0 if credentials are correct
else:
    exit(1)  # Exit with status 1 if credentials are incorrect
END
}

while : ; do  # This creates an infinite loop, which will only be broken when the SMTP credentials are verified successfully
    whiptail --title "Email Setup" --msgbox "Let's set up email notifications. You'll receive an encrypted email when someone submits a new message.\n\nAvoid using your primary email address since your password is stored in plaintext.\n\nInstead, we recommend using a Gmail account with a one-time password." 16 64
    EMAIL=$(whiptail --inputbox "Enter the SMTP email:" 8 60 3>&1 1>&2 2>&3)
    NOTIFY_SMTP_SERVER=$(whiptail --inputbox "Enter the SMTP server address (e.g., smtp.gmail.com):" 8 60 3>&1 1>&2 2>&3)
    NOTIFY_PASSWORD=$(whiptail --passwordbox "Enter the SMTP password:" 8 60 3>&1 1>&2 2>&3)
    NOTIFY_SMTP_PORT=$(whiptail --inputbox "Enter the SMTP server port (e.g., 465):" 8 60 3>&1 1>&2 2>&3)

    if test_smtp_credentials; then
        break  # If credentials are correct, break the infinite loop
    else
        whiptail --title "SMTP Credential Error" --msgbox "SMTP credentials are invalid. Please check your SMTP server address, port, email, and password, and try again." 10 60
    fi
done  # End of the loop

# Create a directory for the environment file with restricted permissions
mkdir -p /etc/hushline
chmod 700 /etc/hushline

# Update the environment file
cat << EOL >> /etc/hushline/environment
EMAIL=$EMAIL
NOTIFY_SMTP_SERVER=$NOTIFY_SMTP_SERVER
NOTIFY_PASSWORD=$NOTIFY_PASSWORD
NOTIFY_SMTP_PORT=$NOTIFY_SMTP_PORT
DATABASE_URL='postgresql://hushlineuser:$DB_PASS@localhost/hushlinedb'
EOL
chmod 600 /etc/hushline/environment

# Check for valid domain name format
until [[ $DOMAIN =~ ^[a-zA-Z0-9][a-zA-Z0-9\.-]*\.[a-zA-Z]{2,}$ ]]; do
    DOMAIN=$(whiptail --inputbox "Invalid domain name format. Please enter a valid domain name:" 8 60 3>&1 1>&2 2>&3)
done
export DOMAIN
export EMAIL
export NOTIFY_PASSWORD
export NOTIFY_SMTP_SERVER
export NOTIFY_SMTP_PORT

# Debug: Print the value of the DOMAIN variable
echo "Domain: ${DOMAIN}"

# Create a virtual environment and install dependencies
cd $HOME/hushline
python3 -m venv venv
source venv/bin/activate
pip3 install setuptools-rust
pip3 install flask
pip3 install pgpy
pip3 install gunicorn
pip3 install psycopg2-binary
pip3 install -r requirements.txt

# Create a systemd service
cat >/etc/systemd/system/hushline.service <<EOL
[Unit]
Description=Hush Line Web App
After=network.target
[Service]
User=root
WorkingDirectory=$HOME/hushline
EnvironmentFile=/etc/hushline/environment
ExecStart=$PWD/venv/bin/gunicorn --bind 127.0.0.1:5000 app:app
Restart=always
[Install]
WantedBy=multi-user.target
EOL

# Make config read-only
chmod 444 /etc/systemd/system/hushline.service

systemctl enable hushline.service
systemctl start hushline.service

# Check if the application is running and listening on the expected address and port
sleep 5
if ! netstat -tuln | grep -q '127.0.0.1:5000'; then
    echo "The application is not running as expected. Please check the application logs for more details."
    error_exit
fi

# Create Tor configuration file
mv $HOME/hushline/assets/config/torrc /etc/tor

# Restart Tor service
systemctl restart tor.service
sleep 10

# Get the Onion address
ONION_ADDRESS=$(cat /var/lib/tor/hidden_service/hostname)
SAUTEED_ONION_ADDRESS=$(echo $ONION_ADDRESS | tr -d '.')

# Configure Nginx
cat >/etc/nginx/sites-available/hushline.nginx <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
    
        add_header Strict-Transport-Security "max-age=63072000; includeSubdomains";
        add_header X-Frame-Options DENY;
        add_header Onion-Location http://$ONION_ADDRESS\$request_uri;
        add_header X-Content-Type-Options nosniff;
        add_header Content-Security-Policy "default-src 'self'; frame-ancestors 'none'";
        add_header Permissions-Policy "geolocation=(), midi=(), notifications=(), push=(), sync-xhr=(), microphone=(), camera=(), magnetometer=(), gyroscope=(), speaker=(), vibrate=(), fullscreen=(), payment=(), interest-cohort=()";
        add_header Referrer-Policy "no-referrer";
        add_header X-XSS-Protection "1; mode=block";
}
server {
    listen 80;
    server_name $SAUTEED_ONION_ADDRESS.$DOMAIN;

    location / {
        proxy_pass http://localhost:5000;
    }
}
EOL

# Configure Nginx with privacy-preserving logging
mv $HOME/hushline/assets/nginx/nginx.conf /etc/nginx

ln -sf /etc/nginx/sites-available/hushline.nginx /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

if [ -e "/etc/nginx/sites-enabled/default" ]; then
    rm /etc/nginx/sites-enabled/default
fi
ln -sf /etc/nginx/sites-available/hushline.nginx /etc/nginx/sites-enabled/
(nginx -t && systemctl restart nginx) || error_exit

SERVER_IP=$(curl -s ifconfig.me)
WIDTH=$(tput cols)
whiptail --msgbox --title "Instructions" "\nPlease ensure that your DNS records are correctly set up before proceeding:\n\nAdd an A record with the name: @ and content: $SERVER_IP\n* Add a CNAME record with the name $SAUTEED_ONION_ADDRESS.$DOMAIN and content: $DOMAIN\n* Add a CAA record with the name: @ and content: 0 issue \"letsencrypt.org\"\n" 14 $WIDTH
# Request the certificates
echo "Waiting for 2 minutes to give DNS time to update..."
sleep 120
certbot --nginx -d $DOMAIN,$SAUTEED_ONION_ADDRESS.$DOMAIN --agree-tos --non-interactive --no-eff-email --email ${EMAIL}

# Set up cron job to renew SSL certificate
(
    crontab -l 2>/dev/null
    echo "30 2 * * 1 /usr/bin/certbot renew --quiet"
) | crontab -

# System status indicator
display_status_indicator() {
    local status="$(systemctl is-active hushline.service)"
    if [ "$status" = "active" ]; then
        printf "\n\033[32m●\033[0m Hush Line is running\nhttps://$DOMAIN\nhttp://$ONION_ADDRESS\n\n"
    else
        printf "\n\033[31m●\033[0m Hush Line is not running\n\n"
    fi
}

# Create Info Page
cat >$HOME/hushline/templates/info.html <<EOL
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="author" content="Science & Design, Inc.">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="A reasonably private and secure personal tip line.">
    <meta name="theme-color" content="#7D25C1">

    <title>Hush Line Info</title>

    <link rel="apple-touch-icon" sizes="180x180" href="{{ url_for('static', filename='favicon/apple-touch-icon.png') }}">
    <link rel="icon" type="image/png" href="{{ url_for('static', filename='favicon/favicon-32x32.png') }}" sizes="32x32">
    <link rel="icon" type="image/png" href="{{ url_for('static', filename='favicon/favicon-16x16.png') }}" sizes="16x16">
    <link rel="icon" type="image/png" href="{{ url_for('static', filename='favicon/android-chrome-192x192.png') }}" sizes="192x192">
    <link rel="icon" type="image/png" href="{{ url_for('static', filename='favicon/android-chrome-512x512.png') }}" sizes="512x512">
    <link rel="icon" type="image/x-icon" href="{{ url_for('static', filename='favicon/favicon.ico') }}">
    <link rel="stylesheet" href="{{ url_for('static', filename='style.css') }}">
</head>
<body class="info">
    <header>
        <div class="wrapper">
            <h1><a href="/">🤫 Hush Line</a></h1>
            <a href="https://www.wikipedia.org" class="btn" rel="noopener noreferrer">Close App</a>
        </div>
    </header>
    <section>
        <div class="wrapper">
            <h2>👋<br>Welcome to Hush Line</h2>
            <p><a href="https://hushline.app" target="_blank" rel="noopener noreferrer">Hush Line</a> is an anonymous tip line. You should use it when you have information you think shows evidence of wrongdoing, including:</p>
            <ul>
                <li>a violation of law, rule, or regulation,</li>
                <li>gross mismanagement,</li>
                <li>a gross waste of funds,</li>
                <li>abuse of authority, or</li>
                <li>a substantial danger to public health or safety.</li>
            </ul>
            <p>⚠️ If you have an elevated threat level - government whistleblowers or users in areas experiencing internet censorship, for example - only use <a href="https://www.torproject.org/download/" target="_blank" aria-label="Learn about Tor Browser" rel="noopener noreferrer">Tor Browser</a> when submitting a message.</p>
            <p>To send a Hush Line message from Tor Browser, visit: <pre>http://$ONION_ADDRESS</pre></p>
            <p>If you prefer to use a browser like Firefox, Safari, or Chrome, you can submit a Hush Line message here: <pre>https://$DOMAIN</pre></p>
            <p>🆘 If you're in immediate danger, stop what you're doing and contact your local authorities.</p>
            <p><a href="https://hushline.app" target="_blank" aria-label="Learn about Hush Line" rel="noopener noreferrer">Hush Line</a> is a free and open-source product by <a href="https://scidsg.org" aria-label="Learn about Science & Design, Inc." target="_blank" rel="noopener noreferrer">Science & Design, Inc.</a> If you've found this tool helpful, <a href="https://opencollective.com/scidsg" target="_blank" aria-label="Donate to support our work" rel="noopener noreferrer">please consider supporting our work!</p>
        </div>
    </section>
    <script src="{{ url_for('static', filename='jquery-min.js') }}"></script>
    <script src="{{ url_for('static', filename='main.js') }}"></script>
</body>
</html>
EOL

# Enable the "security" and "updates" repositories
mv $HOME/hushline/assets/config/50unattended-upgrades /etc/apt/apt.conf.d
mv $HOME/hushline/assets/config/20auto-upgrades /etc/apt/apt.conf.d

systemctl restart unattended-upgrades

echo "Automatic updates have been installed and configured."

# Configure Fail2Ban

echo "Configuring fail2ban..."

systemctl start fail2ban
systemctl enable fail2ban
cp /etc/fail2ban/jail.{conf,local}

# Configure fail2ban
mv $HOME/hushline/assets/config/jail.local /etc/fail2ban

systemctl restart fail2ban

# Configure UFW (Uncomplicated Firewall)

echo "Configuring UFW..."

# Default rules
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp

# Allow SSH (modify as per your requirements)
ufw allow ssh
ufw limit ssh/tcp

# Enable UFW non-interactively
echo "y" | ufw enable

echo "UFW configuration complete."

HUSHLINE_PATH=""

# Detect the environment (Raspberry Pi or VPS) based on some characteristic
if [[ $(uname -n) == *"hushline"* ]]; then
    HUSHLINE_PATH="$HOME/hushline"
else
    HUSHLINE_PATH="/root/hushline" # Adjusted to /root/hushline for the root user on VPS
fi

send_email() {
    python3 << END
import smtplib
import os
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
import pgpy
import warnings
from cryptography.utils import CryptographyDeprecationWarning

warnings.filterwarnings("ignore", category=CryptographyDeprecationWarning)

def send_notification_email(smtp_server, smtp_port, email, password):
    subject = "🎉 Hush Line Installation Complete"
    message = "Hush Line has been successfully installed!\n\nYour Hush Line addresses are:\nhttps://$DOMAIN\nhttp://$ONION_ADDRESS\n\nTo send a message, enter your onion address into Tor Browser, or the non-onion address into a browser like Firefox, Chrome, or Safari. To find information about your Hush Line, including tips for when to use it, visit: http://$ONION_ADDRESS/info or https://$DOMAIN/info. If you still need to download Tor Browser, get it from https://torproject.org/download.\n\nHush Line is a free and open-source tool by Science & Design, Inc. Learn more about us at https://scidsg.org.\n\nIf you've found this resource useful, please consider making a donation at https://opencollective.com/scidsg."

    # Load the public key from its path
    key_path = os.path.expanduser('$HUSHLINE_PATH/public_key.asc')  # Use os to expand the path
    with open(key_path, 'r') as key_file:
        key_data = key_file.read()
        PUBLIC_KEY, _ = pgpy.PGPKey.from_blob(key_data)

    # Encrypt the message
    encrypted_message = str(PUBLIC_KEY.encrypt(pgpy.PGPMessage.new(message)))

    # Construct the email
    msg = MIMEMultipart()
    msg['From'] = email
    msg['To'] = email
    msg['Subject'] = subject
    msg.attach(MIMEText(encrypted_message, 'plain'))

    try:
        server = smtplib.SMTP_SSL(smtp_server, smtp_port)
        server.login(email, password)
        server.sendmail(email, [email], msg.as_string())
        server.quit()
    except Exception as e:
        print(f"Failed to send email: {e}")

send_notification_email("$NOTIFY_SMTP_SERVER", $NOTIFY_SMTP_PORT, "$EMAIL", "$NOTIFY_PASSWORD")
END
}

echo "
✅ Installation complete!
                                               
Hush Line is a product by Science & Design. 
Learn more about us at https://scidsg.org.
Have feedback? Send us an email at hushline@scidsg.org."

# Display system status on login
echo "display_status_indicator() {
    local status=\"\$(systemctl is-active hushline.service)\"
    if [ \"\$status\" = \"active\" ]; then
        printf \"\n\033[32m●\033[0m Hush Line is running\nhttps://$DOMAIN\nhttp://$ONION_ADDRESS\n\n\"
    else
        printf \"\n\033[31m●\033[0m Hush Line is not running\n\n\"
    fi
}" >>/etc/bash.bashrc

echo "display_status_indicator" >>/etc/bash.bashrc
source /etc/bash.bashrc

systemctl restart hushline

rm -r $HOME/hushline/assets

send_email

# Disable the trap before exiting
trap - ERR

# Reboot the device
echo "Rebooting..."
sleep 5
reboot
