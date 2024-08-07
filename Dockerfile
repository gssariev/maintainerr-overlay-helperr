# Use the official PowerShell image from the Microsoft Container Registry
FROM mcr.microsoft.com/powershell:7.1.3-ubuntu-20.04

# Install necessary packages for your script
RUN apt-get update && apt-get install -y \
    libgdiplus \
    libc6-dev \
    && apt-get clean

# Copy the PowerShell script and fonts into the container
COPY maintainerr_days_left.ps1 /maintainerr_days_left.ps1
COPY AvenirNextLTPro-Bold.ttf /fonts/AvenirNextLTPro-Bold.ttf

# Set the working directory
WORKDIR /

# Run the PowerShell script
CMD ["pwsh", "/maintainerr_days_left.ps1"]
