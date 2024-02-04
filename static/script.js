document.addEventListener('DOMContentLoaded', function() {
    // Initialize Stripe with your Stripe publishable key
    var stripe = Stripe('pk_live_51LjpHPEC34n15PioFau4PwFjhwuoYkYY9d5qCh3V36CA6BZqRGhHIaZitXa2eXvyLTDaNRoOSAYmKdNQhaagsgI700zHE13Gk8');

    // Handle mobile navigation toggle
    const mobileNavButton = document.querySelector('.mobileNav');
    const navMenu = document.querySelector('header nav ul');
    
    mobileNavButton.addEventListener('click', function() {
        navMenu.classList.toggle('show');
    });

    // Handle account deletion confirmation
    const deleteButton = document.getElementById('deleteAccountButton');

    if (deleteButton) {
        deleteButton.addEventListener('click', function(event) {
            const confirmed = confirm('Are you sure you want to delete your account? This cannot be undone.');
            if (!confirmed) {
                event.preventDefault();
            }
        });
    }

    // Mailvelope decryption logic
    const encryptedMessages = document.querySelectorAll('.message.encrypted');

    encryptedMessages.forEach(messageElement => {
        const encryptedContent = messageElement.dataset.encryptedContent;
        const decryptionContainer = messageElement.querySelector('.mailvelope-decryption-container');

        if (window.mailvelope) {
            mailvelope.createDisplayContainer({
                id: decryptionContainer.getAttribute('id'),
                encryptedMsg: encryptedContent
            }).then(displayContainer => {
                messageElement.querySelector('.decrypted-content').style.display = 'none'; // Hide original content
                decryptionContainer.appendChild(displayContainer.element);
            }).catch(error => {
                console.error('Decryption error:', error);
                // Handle error or inform user
            });
        } else {
            console.log('Mailvelope not detected');
            // Inform user or provide instructions for installing Mailvelope
        }
    });
});
