# Maintainerr Overlay Helperr

**Project inspired by [Maintainerr Poster Overlay](https://gitlab.com/jakeC207/maintainerr-poster-overlay)**


This project is a helper script that works in combination with Maintainerr, adding a Netflix-style "leaving soon" overlay on top of your media. It integrates with Plex and Maintainerr to download posters, add overlay text, and upload the modified posters back to Plex. It runs periodically to ensure posters are updated with the correct information.

<img width="1144" alt="preview" src="https://github.com/user-attachments/assets/20ea3dd1-fb39-4431-b093-08241a3a4615">

### Features

- Fetches data from Maintainerr.
- Downloads posters from Plex.
- Adds customizable overlay text to the posters.
- Uploads the modified posters back to Plex.
- Runs periodically based on a configurable interval.

### Requirements

- Docker
- Plex Media Server
- Maintainerr

### Usage

#### Docker
1. Build and Run the Container

Create a **docker-compose.yml** file with the following content:
```yaml
services:
  maintainerr-overlay-helperr:
    image: gsariev/maintainerr-overlay-helperr:latest
    environment:
      PLEX_URL: "http://plex-server-ip:32400"
      PLEX_TOKEN: "PLEX-TOKEN"
      MAINTAINERR_URL: "http://maintainerr-ip:6246/api/collections"
      IMAGE_SAVE_PATH: "/images"
      ORIGINAL_IMAGE_PATH: "/images/originals"
      TEMP_IMAGE_PATH: "/images/temp"

      # Change the values here to customize the overlay
      FONT_PATH: "/fonts/AvenirNextLTPro-Bold.ttf"
      FONT_COLOR: "#ffffff"
      BACK_COLOR: "#B20710"
      FONT_SIZE: "45"
      PADDING: "15"
      BACK_RADIUS: "20"
      HORIZONTAL_OFFSET: "80"
      HORIZONTAL_ALIGN: "center"
      VERTICAL_OFFSET: "40"
      VERTICAL_ALIGN: "top"
      
      RUN_INTERVAL: "2"  # Set the run interval to after X minutes; default is 480 minutes (8 hours) if not specified
    volumes:
      - ./images:/images
      - ./fonts:/fonts
    network_mode: "bridge"
```
2. Run the container
```yaml
docker-compose up --build
```
#### Ensure Directories Exist

- Ensure the directories specified in IMAGE_SAVE_PATH, ORIGINAL_IMAGE_PATH, and TEMP_IMAGE_PATH exist on your system.
- Ensure that the font file you are going to use is present in the mapped 'fonts' folder prior to running the script.
- The script will automatically run every RUN_INTERVAL minutes. If the interval is not specified, it defaults to 8 hours.
