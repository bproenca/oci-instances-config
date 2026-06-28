
## Configure crontab to monitor apps

```sh
crontab -e

# Every 2 Hours	0 */2 * * *
0 */2 * * * /home/ubuntu/wks/health_check.sh >> /home/ubuntu/wks/cron.log 2>&1

# Every 10 Minutes	*/10 * * * *
*/10 * * * * /home/ubuntu/wks/health_check.sh >> /home/ubuntu/wks/cron.log 2>&1

# Every 12 Hours	0 */12 * * *
0 */12 * * * /home/ubuntu/wks/health_check.sh >> /home/ubuntu/wks/cron.log 2>&1

```