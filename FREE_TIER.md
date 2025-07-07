how to leverage oracle's temping offers

## free tier limits

The limits of the free tier say that you can create up to 4 instances.
- x2 x86 instances (2core/1g)
- x2 ampere instances (with 4core/24g spread between them)
- 200GB total boot volume space across all intances (minimum of 50G per instance)

## create your account

The first step is to create your oracle cloud account here: https://signup.cloud.oracle.com/

You will need a valid credit card for signup, "We do not accept virtual cards or prepaid cards. We accept credit cards and debit cards only."

## login

Log into your new account you created above.

![SignIn](https://user-images.githubusercontent.com/7338312/113791051-60882600-9708-11eb-801e-3f0624aca2dc.png)

## create a vm instance

On the home screen, there should be a hamberger button in the top left. Click it, and the resource pane opens. Select "Compute" and then "Instances".

![image](https://user-images.githubusercontent.com/7338312/144918356-a91aa72c-2bf7-4964-bf35-e3032c4e00c2.png)

Click on the "Create instance" button on the next page.

![image](https://user-images.githubusercontent.com/7338312/144918469-c98f44dc-306e-440c-ab10-00c9b7ea62c1.png)


## name & region

Enter a name for your instance. Then give the form a second to autofill, and a region should be selected with the "Always Free-eligible" badge to the right.

![image](https://user-images.githubusercontent.com/7338312/144918675-3e4fbce2-875e-4ac1-ae7a-d18d66fd2f4a.png)

## shape

Click "edit" next to "Image and Shape", and then "Change shape".

![image](https://user-images.githubusercontent.com/7338312/144918846-4c250858-01a4-41bf-ba4d-bf5015a59534.png)

### x86

To create an instance with an x86 based processor, just leave everything default and click "Select shape".

![image](https://user-images.githubusercontent.com/7338312/144919139-0e53da3e-ccc2-4d5a-b42d-c3651fc056f0.png)

### arm

To create an instance with an arm processor, select "Ampere" and then check the box next to "VM.Standard.A1.Flex".

![image](https://user-images.githubusercontent.com/7338312/144945509-1d6f269e-47c9-4749-9281-b93c947637a2.png)

Then you are given a CPU and Memory slider. You have 4 cores and 24G to use between your (max of) 2 instances. You can give one instance all 4 cores and 24G or make two instances with a variable size.

![image](https://user-images.githubusercontent.com/7338312/144945640-2809fc13-cc2b-4c36-b033-050da631ff02.png)

## image

Click on "Change image" next.

![image](https://user-images.githubusercontent.com/7338312/144919299-d39c916b-94e5-4f1a-a25d-20ec6b4d257e.png)

This choice is personal preference. Choose the Image Name, OS, and Build based on what you need.

![image](https://user-images.githubusercontent.com/7338312/144919489-20ac31e0-bfe0-4788-a0f2-ff930468b7b0.png)

Then click "Select image" at the bottom.

## networking

I usually don't change any defaults here, but you can at your discretion.

## ssh keys

Next, under the ssh section, select "paste public keys" and paste in your public key (normally found in `~/.ssh/id_rsa.pub` in most \*nix like systems). You can also upload that file, or generate a key-pair from within the options.

![image](https://user-images.githubusercontent.com/7338312/144919789-c456c22b-8943-4ad0-a784-b94ab084c022.png)

## boot volume

Most of the time this section can be left as default.

![image](https://user-images.githubusercontent.com/7338312/144945033-f2d602b8-b7f9-438b-be66-3e9a04bbe56a.png)

You have 200G of disk space in the free tier, and if you use up 4 VMs then the minimum disk size of 50G (the default) is fine. If you plan to make fewer instances than 4, you can adjust the size as needed.

## deploy

![image](https://user-images.githubusercontent.com/7338312/144945150-7373060d-77d8-45a8-a456-4eb99463adcb.png)

You will be dropped to a loading screen, and after a few it will turn green and display a public ip that you can now `ssh` with the username `ubuntu` and the private key of the public one you specified above.

![done](https://user-images.githubusercontent.com/7338312/113791880-3d5e7600-970a-11eb-9e04-0ffefa5defbf.png)

`ssh ubuntu@150.136.139.99`
