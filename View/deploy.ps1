$gcloud = "C:\Users\omar.elfarouklakhdar\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"
& $gcloud compute scp --zone=us-central1-a --recurse dist/index.html dist/assets martin-tileserver:/home/omarlakhdhar_gmail_com/rust-map-server/View/dist/
