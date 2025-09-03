# Onboarding

# Initial onboarding: Creates factory1-1 through factory1-5
./10_onboard_things.sh factory1 5

# Add more machines later: Auto-creates factory1-6 through factory1-10  
./10_onboard_things.sh factory1 5

# Add specific range: Creates factory1-15 through factory1-17
./10_onboard_things.sh factory1 3 --start-from 15