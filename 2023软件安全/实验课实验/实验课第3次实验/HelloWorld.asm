#/usr/bin/env python
# ѵ��ģ��ʹ�õĽű���net1��net2�Ǽ�������������������ģ�ͣ�net3������IMģ���ģ��
import sys
import os
import torch
import torch.nn
import torch.optim
import torchvision
import torch.nn.functional as F
import math
import numpy as np
import tqdm                                     # ��ʾѵ������
from model import *                             # ��model.py�е��붨�������ģ�ͣ�Ӧ����net1��net2��
from imp_subnet import *                        # ��imp_subnet.py�е��붨�������ģ�ͣ�Ӧ����net3��
import torchvision.transforms as T              # TorchVision���е�ͼ��ת��ģ��
import config as c                              # ���������ļ�config.py
from tensorboardX import SummaryWriter          # ���ڿ��ӻ�ѵ������
from datasets import trainloader, testloader    # �������ѵ�����ݺͲ������ݵ�ģ��
import viz
import modules.module_util as mutil
import modules.Unet_common as common
import warnings
from vgg_loss import VGGLoss                    # �����ʵ����û����
warnings.filterwarnings("ignore")

# ѡ��GPU
device = torch.device("cuda:0" if torch.cuda.is_available() else "cpu")


# ����ͼ��ķ�ֵ�����(PSNR)���Ǻ���ͼ��������ָ�꣬��ֵԽ�߱�ʾͼ������Խ��
# --> ����֤��ʱ���Ա�ԭʼ����ͼ������ȡ��������ͼ��ԭʼ����ͼ���Ƕ��������ͼ��
def computePSNR(origin, pred):
    # ������ת��Ϊ��������
    origin = np.array(origin)
    origin = origin.astype(np.float32)
    pred = np.array(pred)
    pred = pred.astype(np.float32)
    # ������������
    mse = np.mean((origin / 1.0 - pred / 1.0) ** 2)
    # ����СMSE�ͼ���MSE���
    if mse < 1.0e-10:
        return 100

    if mse > 1.0e15:
        return -100

    return 10 * math.log10(255.0 ** 2 / mse)


# ���ɸ�˹����
def gauss_noise(shape):
    # ʹ��PyTorch����һ����������״��ͬ����������Ȼ���ÿ������Ӧ�þ�ֵΪ0������Ϊ1�ĸ�˹�ֲ���������
    noise = torch.zeros(shape).to(device)
    for i in range(noise.shape[0]):
        noise[i] = torch.randn(noise[i].shape).to(device)

    return noise


########### ������һ����ʧ����������ָ��ģ��ѵ�� #################
##### ���У�L1��ʧ��ָƽ��������L2��ʧ��ָ�������(MSE) #############
# ������ʧ(ȷ�����ɵ���дͼ����ԭʼͼ������)
def guide_loss(output, bicubic_image):
    # ʹ�þ��������ʧ������MSELoss������ģ�������˫���β�ֵͼ��֮��Ĳ���
    loss_fn = torch.nn.MSELoss(reduce=True, size_average=False)
    loss = loss_fn(output, bicubic_image)
    return loss.to(device)

# �ؽ���ʧ(ȷ���Ա���ȡ��������ͼ����ԭʼ����ͼ������)
def reconstruction_loss(rev_input, input):
    loss_fn = torch.nn.MSELoss(reduce=True, size_average=False)
    loss = loss_fn(rev_input, input)
    return loss.to(device)

# Imp��ʧ(output ��ģ�͵������resi �ǲв�(ģ�������ȥ����))
def imp_loss(output, resi):
    loss_fn = torch.nn.MSELoss(reduce=True, size_average=False)
    loss = loss_fn(output, resi)
    return loss.to(device)

# ��Ƶ��ʧ(ȷ�����ɵ�ͼ���ڵ�Ƶ���ֱ�������)
# -->������û���õ������ʧ����������ֱ����ȡ��ͼ���Ƶ����Ȼ�����guide_loss��Ϊ��Ƶ��ʧ
def low_frequency_loss(ll_input, gt_input):
    # ʹ�� L1 ��ʧ���������Ƶ����֮��Ĳ���
    loss_fn = torch.nn.L1Loss(reduce=True, size_average=False)
    loss = loss_fn(ll_input, gt_input)
    return loss.to(device)

# �ֲ���ʧ(noise��ģ�����������,����ģ�������������������֮��Ĳ���)
# -->������Ҳû���õ������ʧ����
def distr_loss(noise):
    loss_fn = torch.nn.MSELoss(reduce=True, size_average=False)
    loss = loss_fn(noise, torch.zeros(noise.shape).cuda())
    return loss.to(device)
################# end ###############################


# ��ȡnet�����������
def get_parameter_number(net):
    total_num = sum(p.numel() for p in net.parameters())
    trainable_num = sum(p.numel() for p in net.parameters() if p.requires_grad)
    return {'Total': total_num, 'Trainable': trainable_num}


# ����ģ��Ȩ�أ�������������ص�ģ���в����Լ����Ż�����״̬�ֵ�
def load(name, net, optim):
    state_dicts = torch.load(name)
    network_state_dict = {k: v for k, v in state_dicts['net'].items() if 'tmp_var' not in k}
    net.load_state_dict(network_state_dict)
    try:
        optim.load_state_dict(state_dicts['opt'])
    except:
        print('Cannot load optimizer for some reason or other')


# ��ʼ��net3(IM)�������
def init_net3(mod):
    for key, param in mod.named_parameters():
        if param.requires_grad:
            param.data = 0.1 * torch.randn(param.data.shape).to(device)




if __name__ == '__main__':

    #####################
    # Model initialize: #
    #####################
    # ��ʼ��ģ��
    net1 = Model_1()
    net2 = Model_2()
    net3 = ImpMapBlock()
    # ��ģ���ƶ��� GPU
    net1.cuda()
    net2.cuda()
    net3.cuda()
    # ģ�Ͳ�����ʼ��
    init_model(net1)
    init_model(net2)
    init_net3(net3)
    # ʹ�� DataParallel ���в��л���ͬʱѵ������ģ��
    net1 = torch.nn.DataParallel(net1, device_ids=c.device_ids)
    net2 = torch.nn.DataParallel(net2, device_ids=c.device_ids)
    net3 = torch.nn.DataParallel(net3, device_ids=c.device_ids)
    # ��ȡ����ӡģ�Ͳ�������
    para1 = get_parameter_number(net1)
    para2 = get_parameter_number(net2)
    para3 = get_parameter_number(net3)
    print(para1)
    print(para2)
    print(para3)
    # ��ȡ��ѵ�������б�ͳ�ʼ���Ż���
    params_trainable1 = (list(filter(lambda p: p.requires_grad, net1.parameters())))
    params_trainable2 = (list(filter(lambda p: p.requires_grad, net2.parameters())))
    params_trainable3 = (list(filter(lambda p: p.requires_grad, net3.parameters())))
    optim1 = torch.optim.Adam(params_trainable1, lr=c.lr, betas=c.betas, eps=1e-6, weight_decay=c.weight_decay)
    optim2 = torch.optim.Adam(params_trainable2, lr=c.lr, betas=c.betas, eps=1e-6, weight_decay=c.weight_decay)
    optim3 = torch.optim.Adam(params_trainable3, lr=c.lr3, betas=c.betas, eps=1e-6, weight_decay=c.weight_decay)
    # ��ʼ��ѧϰ�ʵ�����
    weight_scheduler1 = torch.optim.lr_scheduler.StepLR(optim1, c.weight_step, gamma=c.gamma)
    weight_scheduler2 = torch.optim.lr_scheduler.StepLR(optim2, c.weight_step, gamma=c.gamma)
    weight_scheduler3 = torch.optim.lr_scheduler.StepLR(optim3, c.weight_step, gamma=c.gamma)
    # ��ʼ����ɢС���任�ͷ���ɢС���任
    dwt = common.DWT()
    iwt = common.IWT()

    # �ж��Ƿ�Ҫ������һ��ѵ����ģ��
    # -->ѵ�����̷����쳣�����õ�������Լ�����һ�ֵ�ģ�ͼ���ѵ����readme��Ҳ�ᵽ���ܻ�����ݶȱ�ը���������Ҫ�ֶ�ֹͣ������ѧϰ�ʣ�
    if c.tain_next:
        load(c.MODEL_PATH + c.suffix_load + '_1.pt', net1, optim1)
        load(c.MODEL_PATH + c.suffix_load + '_2.pt', net2, optim2)
        load(c.MODEL_PATH + c.suffix_load + '_3.pt', net3, optim3)

    # �ж��Ƿ�Ҫ����Ԥѵ��ģ��
    if c.pretrain:
        load(c.PRETRAIN_PATH + c.suffix_pretrain + '_1.pt', net1, optim1)
        load(c.PRETRAIN_PATH + c.suffix_pretrain + '_2.pt', net2, optim2)
        if c.PRETRAIN_PATH_3 is not None:
            load(c.PRETRAIN_PATH_3 + c.suffix_pretrain_3 + '_3.pt', net3, optim3)

    try:
        # ���Դ���һ������ TensorBoardX ���ӻ�ѵ�����̵� SummaryWriter
        writer = SummaryWriter(log_dir='scalar', comment='hinet', filename_suffix="steg")

        for i_epoch in range(c.epochs):
            # ѵ�������ĳ�ʼ��
            i_epoch = i_epoch + c.trained_epoch + 1
            loss_history = []
            loss_history_g1 = []
            loss_history_g2 = []
            loss_history_r1 = []
            loss_history_r2 = []
            loss_history_imp = []
            loss_history_roubst = []
            #################
            #     train:    #
            #################
            vgg_loss = VGGLoss(3, 1, False)
            vgg_loss.to(device)
            # �ڲ�ѭ������ÿ�� mini-batch����׼��ѵ������
            for i_batch, data in enumerate(trainloader):
                # ����׼��(�������ƶ���GPU�������ݷ�Ϊ cover ������ secret, ������dwt�任)
                data = data.to(device)
                """
                ������Ĵ����У���`data`������һϵ�е���Ƭ����������ֳ����������֣��ֱ�ֵ����`cover`��`secret_1`��`secret_2`��
                - `secret_1`����ʾ��`data`�м䲿����ȡ�����ݡ�������˵��`secret_1`��ȡֵ��Χ��`data`�ĳ��ȵ�1/3��2/3֮�䡣����ζ��`secret_1`������`data`�м�1/3���ȵ����ݡ�
                - `secret_2`��ȡֵ��Χ��`data`�ĳ��ȵ�2/3�����峤��֮�䡣����ζ��`secret_2`������`data`��1/3���ȵ����ݡ�
                """
                cover = data[:data.shape[0] // 3]  # channels = 3
                secret_1 = data[data.shape[0] // 3: 2 * (data.shape[0] // 3)]
                secret_2 = data[2 * (data.shape[0] // 3): 3 * (data.shape[0] // 3)]
                cover_dwt = dwt(cover)  # channels = 12
                cover_dwt_low = cover_dwt.narrow(1, 0, c.channels_in)  # channels = 3
                secret_dwt_1 = dwt(secret_1)
                secret_dwt_2 = dwt(secret_2)

                # ��cover_dwt��secret_dwt_1����ͨ��ά��ƴ�ӣ�������������
                input_dwt_1 = torch.cat((cover_dwt, secret_dwt_1), 1)  # channels = 24


                #################
                #  ��һ��ǰ�򴫲�-->net1��������secret1
                #################
                output_dwt_1 = net1(input_dwt_1)  # channels = 24
                output_steg_dwt_1 = output_dwt_1.narrow(1, 0, 4 * c.channels_in)  # channels = 12
                # ��ȡoutput_steg_dwt_low_1��Ŀ����Ϊ�˼����Ƶ��ʧlow_frequency_loss
                output_steg_dwt_low_1 = output_steg_dwt_1.narrow(1, 0, c.channels_in)  # channels = 3
                output_z_dwt_1 = output_dwt_1.narrow(1, 4 * c.channels_in, 4 * c.channels_in)  # channels = 12

                # ��dwt�任�õ�Ƕ���һ������ͼ��������ͼ��
                output_steg_1 = iwt(output_steg_dwt_1).to(device)  # channels = 3


                #################
                #    �ڶ���ǰ�򴫲�-->net3��������IMģ�飬net2��������secret2
                #################
                if c.use_imp_map:
                    # ���Ҫʹ��IMģ�飬����imp_map
                    imp_map = net3(cover, secret_1, output_steg_1)  # channels = 3
                else:
                    # ��ʹ���������״��ͬ��������
                    imp_map = torch.zeros(cover.shape).cuda()

                # ����imploss
                impmap_loss = imp_loss(imp_map, cover - output_steg_1)

                # ��imp_map����dwt
                imp_map_dwt = dwt(imp_map)  # channels = 12
                # ��output_steg_dwt_1��imp_map_dwt����ͨ��ά��ƴ�ӣ�������������
                input_dwt_2 = torch.cat((output_steg_dwt_1, imp_map_dwt), 1)  # 24, without secret2

                # ��ڶ�������ͼ��С���ź� (secret_dwt_2) ƴ�ӣ���������������
                input_dwt_2 = torch.cat((input_dwt_2, secret_dwt_2), 1)  # 36

                # ��net1ͬ��net2Ƕ��ڶ���ͼ��
                output_dwt_2 = net2(input_dwt_2)  # channels = 36
                output_steg_dwt_2 = output_dwt_2.narrow(1, 0, 4 * c.channels_in)  # channels = 12
                output_steg_dwt_low_2 = output_steg_dwt_2.narrow(1, 0, c.channels_in)  # channels = 3
                output_z_dwt_2 = output_dwt_2.narrow(1, 4 * c.channels_in, output_dwt_2.shape[1] - 4 * c.channels_in)  # channels = 24

                # get steg2
                output_steg_2 = iwt(output_steg_dwt_2)  # channels = 3
                #print(output_steg_2)

                #----------------³����ģ��(��config)-------------------#
                if (c.choice_attack == 1):
                    # ��steg_2�����������
                    noise = torch.randn_like(output_steg_2) * c.noise_level
                    #print(noise)
                    # ��������ӵ����ͼ��
                    output_steg_2_with_noise = output_steg_2 + noise
                    # ʹ��clamp������ֵ�����ں���Χ�ڣ����ⳬ��������������
                    floor_level = torch.min(output_steg_2)
                    upper_level = torch.max(output_steg_2)
                    output_steg_2_with_noise = output_steg_2_with_noise.clamp(floor_level, upper_level)
                    # dwt�仯�õ����򴫲�������
                    output_steg_dwt_2_with_noise = dwt(output_steg_2_with_noise)
                    output_steg_dwt_low_with_noise = output_steg_dwt_2_with_noise.narrow(1, 0, c.channels_in)  # channels = 3

                elif (c.choice_attack == 2):
                    # ��������������������ĸ�����ֵת��Ϊ�ϵ͵�λ������ģ��PNGͼ���8λɫ��
                    output_steg_2_toPNG = torch.floor(output_steg_2 * 255) / 255.0
                    #print(output_steg_2_toPNG)
                    # dwt�仯�õ����򴫲�������
                    output_steg_dwt_2_toPNG = dwt(output_steg_2_toPNG)
                    output_steg_dwt_low_toPNG = output_steg_dwt_2_toPNG.narrow(1, 0, c.channels_in)

                else:
                    pass
                #--------------------end------------------------#


                #################
                #  �ڶ������򴫲�-->����net2������ָ̻��ڶ���Ƕ�������ͼ�� 
                #################

                # ����Ƕ��ͼ��ʱ�����������ֲ���ͬ�ĸ�˹���������ڻָ�Ƕ���ͼ��
                output_z_guass_1 = gauss_noise(output_z_dwt_1.shape)  # channels = 12
                output_z_guass_2 = gauss_noise(output_z_dwt_2.shape)  # channels = 24

                #output_steg_dwt_2=dwt(output_steg_2)
                
                if (c.choice_attack == 1):
                    output_steg_dwt_2 = output_steg_dwt_2_with_noise
                elif (c.choice_attack == 2):
                    output_steg_dwt_2 = output_steg_dwt_2_toPNG
                else:
                    pass
                

                # �� output_steg_dwt_2 �͸�˹����ƴ�ӣ��õ����򴫲�������
                output_rev_dwt_2 = torch.cat((output_steg_dwt_2, output_z_guass_2), 1)  # channels = 36

                # ʹ��net2����������ָ�Ƕ��ĵڶ���ͼ��
                rev_dwt_2 = net2(output_rev_dwt_2, rev=True)  # channels = 36

                # �õ�����ͼ���dwt��secret2��dwt
                rev_steg_dwt_1 = rev_dwt_2.narrow(1, 0, 4 * c.channels_in)  # channels = 12
                # rev_secret_dwt_2 = rev_dwt_2.narrow(1, 4 * c.channels_in, 4 * c.channels_in)  # channels = 12
                rev_secret_dwt_2 = rev_dwt_2.narrow(1, rev_dwt_2.shape[1] - 4 * c.channels_in, 4 * c.channels_in)

                # ��dwt�ָ�steg1��secret2
                rev_steg_1 = iwt(rev_steg_dwt_1).to(device)  # channels = 3
                rev_secret_2 = iwt(rev_secret_dwt_2).to(device)  # channels = 3

                #################
                #   ��һ�����򴫲�-->ͬ������net1������ָ̻���һ��Ƕ�������ͼ��
                #################
                output_rev_dwt_1 = torch.cat((rev_steg_dwt_1, output_z_guass_1), 1)  # channels = 24

                rev_dwt_1 = net1(output_rev_dwt_1, rev=True)  # channels = 36

                rev_secret_dwt = rev_dwt_1.narrow(1, 4 * c.channels_in, 4 * c.channels_in)  # channels = 12
                rev_secret_1 = iwt(rev_secret_dwt).to(device)

                #################
                #     loss:     #
                #################
                # ����guide_loss\low_frequency_loss\reconstruction_loss
                g_loss_1 = guide_loss(output_steg_1.cuda(), cover.cuda())
                g_loss_2 = guide_loss(output_steg_2.cuda(), cover.cuda())
                
                vgg_on_cov = vgg_loss(cover)
                vgg_on_steg1 = vgg_loss(output_steg_1)
                vgg_on_steg2 = vgg_loss(output_steg_2)
                #vgg_on_secret1 = vgg_loss(secret_1)
                #vgg_on_secret2 = vgg_loss(secret_2)
                #vgg_on_rev_secret1 = vgg_loss(rev_secret_1)
                #vgg_on_rev_secret2 = vgg_loss(rev_secret_2)
                
                #��֪��ʧ
                perc_loss = guide_loss(vgg_on_cov, vgg_on_steg1) + guide_loss(vgg_on_cov, vgg_on_steg2)
                #³����ʧ
                roubst_loss = guide_loss(secret_dwt_1.cuda(),rev_secret_dwt.cuda()) + \
                            guide_loss(secret_dwt_2.cuda(),rev_secret_dwt_2.cuda())
                
                l_loss_1 = guide_loss(output_steg_dwt_low_1.cuda(), cover_dwt_low.cuda())
                l_loss_2 = guide_loss(output_steg_dwt_low_2.cuda(), cover_dwt_low.cuda())
                # ����rev_secret_1��rev_secret_2�ǹ�����ͼ����ȡ������ͼ��
                r_loss_1 = reconstruction_loss(rev_secret_1, secret_1)
                r_loss_2 = reconstruction_loss(rev_secret_2, secret_2)

                # ��ϸ���ʧ��Ȩ�صõ�����ʧ����з��򴫲��Ͳ�������
                # -->��������r_loss_1��r_loss_2��Ȩ��(config)��������֪��³����������Ҫ��
                total_loss = c.lamda_reconstruction_1 * r_loss_1 + c.lamda_reconstruction_2 * r_loss_2 + c.lamda_guide_1 * g_loss_1\
                         + c.lamda_guide_2 * g_loss_2 + c.lamda_low_frequency_1 * l_loss_1 + c.lamda_low_frequency_2 * l_loss_2 \
                         + c.lamda_roubst * roubst_loss
                total_loss = total_loss + 0.01 * perc_loss
                total_loss.backward()

                if c.optim_step_1:
                    optim1.step()

                if c.optim_step_2:
                    optim2.step()

                if c.optim_step_3:
                    optim3.step()

                optim1.zero_grad()
                optim2.zero_grad()
                optim3.zero_grad()

                # ��¼��ʧ��ʷ����ÿ����ʧ���ֵ��¼����Ӧ���б���, ���ں�������
                loss_history.append([total_loss.item(), 0.])
                loss_history_g1.append(g_loss_1.item())
                loss_history_g2.append(g_loss_2.item())
                loss_history_r1.append(r_loss_1.item())
                loss_history_r2.append(r_loss_2.item())
                loss_history_imp.append(impmap_loss.item())
                loss_history_roubst.append(roubst_loss.item())

            #################
            #     val:    #
            #################
            # ģ�������������ǰ epoch ������֤Ƶ�� (val_freq) ������������֤ģʽ 
            if i_epoch % c.val_freq == 1:
                # �����ݶȼ���
                with torch.no_grad():
                    psnr_s1 = []
                    psnr_s2 = []
                    psnr_c1 = []
                    psnr_c2 = []
                    net1.eval()
                    net2.eval()
                    net3.eval()
                    # ׼����֤���ݣ���ѵ���������Ʋ�������
                    for x in testloader:
                        x = x.to(device)
                        cover = x[:x.shape[0] // 3]  # channels = 3
                        secret_1 = x[x.shape[0] // 3: 2 * x.shape[0] // 3]
                        secret_2 = x[2 * x.shape[0] // 3: 3 * x.shape[0] // 3]

                        cover_dwt = dwt(cover)  # channels = 12
                        secret_dwt_1 = dwt(secret_1)
                        secret_dwt_2 = dwt(secret_2)

                        input_dwt_1 = torch.cat((cover_dwt, secret_dwt_1), 1)  # channels = 24

                        #################
                        #    forward1:   #
                        #################
                        output_dwt_1 = net1(input_dwt_1)  # channels = 24
                        output_steg_dwt_1 = output_dwt_1.narrow(1, 0, 4 * c.channels_in)  # channels = 12
                        output_z_dwt_1 = output_dwt_1.narrow(1, 4 * c.channels_in, 4 * c.channels_in)  # channels = 12

                        # get steg1
                        output_steg_1 = iwt(output_steg_dwt_1).to(device)  # channels = 3

                        #################
                        #    forward2:   #
                        #################
                        if c.use_imp_map:
                            imp_map = net3(cover, secret_1, output_steg_1)  # channels = 3
                        else:
                            imp_map = torch.zeros(cover.shape).cuda()

                        imp_map_dwt = dwt(imp_map)  # channels = 12
                        input_dwt_2 = torch.cat((output_steg_dwt_1, imp_map_dwt), 1)  # 24, without secret2
                        input_dwt_2 = torch.cat((input_dwt_2, secret_dwt_2), 1)  # 36

                        output_dwt_2 = net2(input_dwt_2)  # channels = 36
                        output_steg_dwt_2 = output_dwt_2.narrow(1, 0, 4 * c.channels_in)  # channels = 12
                        output_z_dwt_2 = output_dwt_2.narrow(1, 4 * c.channels_in, output_dwt_2.shape[1] - 4 * c.channels_in)  # channels = 24

                        # get steg2
                        output_steg_2 = iwt(output_steg_dwt_2).to(device)  # channels = 3

                        #----------------³����ģ��(��config)-------------------#
                        if (c.choice_attack == 1):
                            # ��steg_2�����������
                            noise = torch.randn_like(output_steg_2) * c.noise_level
                            # ��������ӵ����ͼ��
                            output_steg_2_with_noise = output_steg_2 + noise
                            # ʹ��clamp������ֵ�����ں���Χ�ڣ����ⳬ��������������
                            floor_level = torch.min(output_steg_2)
                            upper_level = torch.max(output_steg_2)
                            output_steg_2_with_noise = output_steg_2_with_noise.clamp(floor_level, upper_level)
                            output_steg_dwt_2_with_noise = dwt(output_steg_2_with_noise)
                            output_steg_dwt_low_with_noise = output_steg_dwt_2_with_noise.narrow(1, 0, c.channels_in)
                            
                        elif (c.choice_attack == 2):
                            output_steg_2_toPNG = torch.floor(output_steg_2 * 255) / 255.0
                            output_steg_dwt_2_toPNG = dwt(output_steg_2_toPNG)
            
                            output_steg_dwt_low_toPNG = output_steg_dwt_2_toPNG.narrow(1, 0, c.channels_in)
                        else:
                            pass
                        #--------------------end------------------------#

                        #################
                        #   backward2:   #
                        #################

                        output_z_guass_1 = gauss_noise(output_z_dwt_1.shape)  # channels = 12
                        output_z_guass_2 = gauss_noise(output_z_dwt_2.shape)  # channels = 24
                        
                        if (c.choice_attack == 1):
                            output_steg_dwt_2 = output_steg_dwt_2_with_noise
                        elif (c.choice_attack == 2):
                            output_steg_dwt_2 = output_steg_dwt_2_toPNG
                        else:
                            pass
                        
                        #�Ķ��������֤����ʹ�ù������ͼƬ��������ͼ�����ȡ������֤��³����
                        #��������ֵ����ȵ�ʱ��ԭʼ����ͼ���Ƕ��������ͼ��ʹ�ù���ǰ��Ƕ�������ͼ����Ϊ������������Ϊ�ӵ�
                        output_rev_dwt_2 = torch.cat((output_steg_dwt_2, output_z_guass_2), 1)  # channels = 36

                        rev_dwt_2 = net2(output_rev_dwt_2, rev=True)  # channels = 36

                        rev_steg_dwt_1 = rev_dwt_2.narrow(1, 0, 4 * c.channels_in)  # channels = 12
                        rev_secret_dwt_2 = rev_dwt_2.narrow(1, output_dwt_2.shape[1] - 4 * c.channels_in, 4 * c.channels_in)  # channels = 12

                        rev_steg_1 = iwt(rev_steg_dwt_1).to(device)  # channels = 3
                        rev_secret_2 = iwt(rev_secret_dwt_2).to(device)  # channels = 3

                        #################
                        #   backward1:   #
                        #################
                        output_rev_dwt_1 = torch.cat((rev_steg_dwt_1, output_z_guass_1), 1)  # channels = 24

                        rev_dwt_1 = net1(output_rev_dwt_1, rev=True)  # channels = 24

                        rev_secret_dwt = rev_dwt_1.narrow(1, rev_dwt_1.shape[1] - 4 * c.channels_in, 4 * c.channels_in)  # channels = 12
                        rev_secret_1 = iwt(rev_secret_dwt).to(device)

                        # �����ֵ�����(ԭʼ����ͼ������ȡ��������ͼ��ԭʼ����ͼ���Ƕ��������ͼ��)
                        secret_rev1_255 = rev_secret_1.cpu().numpy().squeeze() * 255
                        secret_rev2_255 = rev_secret_2.cpu().numpy().squeeze() * 255
                        secret_1_255 = secret_1.cpu().numpy().squeeze() * 255
                        secret_2_255 = secret_2.cpu().numpy().squeeze() * 255

                        cover_255 = cover.cpu().numpy().squeeze() * 255
                        steg_1_255 = output_steg_1.cpu().numpy().squeeze() * 255
                        steg_2_255 = output_steg_2.cpu().numpy().squeeze() * 255

                        psnr_temp1 = computePSNR(secret_rev1_255, secret_1_255)
                        psnr_s1.append(psnr_temp1)
                        psnr_temp2 = computePSNR(secret_rev2_255, secret_2_255)
                        psnr_s2.append(psnr_temp2)

                        psnr_temp_c1 = computePSNR(cover_255, steg_1_255)
                        psnr_c1.append(psnr_temp_c1)
                        psnr_temp_c2 = computePSNR(cover_255, steg_2_255)
                        psnr_c2.append(psnr_temp_c2)

                    # �� PSNR ���м�¼�Ϳ��ӻ�, Ŀ���Ǹ���ģ������֤���ϵ�����
                    writer.add_scalars("PSNR", {"S1 average psnr": np.mean(psnr_s1)}, i_epoch)
                    writer.add_scalars("PSNR", {"C1 average psnr": np.mean(psnr_c1)}, i_epoch)
                    writer.add_scalars("PSNR", {"S2 average psnr": np.mean(psnr_s2)}, i_epoch)
                    writer.add_scalars("PSNR", {"C2 average psnr": np.mean(psnr_c2)}, i_epoch)

            # �������� epoch ��ƽ����ʧ
            epoch_losses = np.mean(np.array(loss_history), axis=0)
            # ��¼��ǰѧϰ�ʵĶ���ֵ��������Ϊ�ڶ���Ԫ����ӵ� epoch_losses �����У����������ڿ��ӻ���׷��ѧϰ�ʵı仯��
            epoch_losses[1] = np.log10(optim1.param_groups[0]['lr'])

            # ����many loss��ƽ��ֵ
            epoch_losses_g1 = np.mean(np.array(loss_history_g1))
            epoch_losses_g2 = np.mean(np.array(loss_history_g2))
            epoch_losses_r1 = np.mean(np.array(loss_history_r1))
            epoch_losses_r2 = np.mean(np.array(loss_history_r2))
            epoch_losses_imp = np.mean(np.array(loss_history_imp))
            epoch_losses_roubst = np.mean(np.array(loss_history_roubst))
            print(f"epoch_losses_g1 : {epoch_losses_g1}")
            print(f"epoch_losses_g2 : {epoch_losses_g2}")
            print(f"epoch_losses_r1 : {epoch_losses_r1}")
            print(f"epoch_losses_r2 : {epoch_losses_r2}")
            print(f"epoch_losses_imp : {epoch_losses_imp}")
            print(f"epoch_losses_roubst : {epoch_losses_roubst}")

            # ʹ�� viz ������ӻ�չʾ��ǰ epoch ����ʧ
            viz.show_loss(epoch_losses)
            writer.add_scalars("Train", {"Train_Loss": epoch_losses[0]}, i_epoch)
            writer.add_scalars("Train", {"g1_Loss": epoch_losses_g1}, i_epoch)
            writer.add_scalars("Train", {"g2_Loss": epoch_losses_g2}, i_epoch)
            writer.add_scalars("Train", {"r1_Loss": epoch_losses_r1}, i_epoch)
            writer.add_scalars("Train", {"r2_Loss": epoch_losses_r2}, i_epoch)
            writer.add_scalars("Train", {"imp_Loss": epoch_losses_imp}, i_epoch)
            writer.add_scalars("Train", {"roubst_Loss": epoch_losses_roubst}, i_epoch)

            # �����ǰ epoch ���� 0 ���Ǳ����Ƶ�ʵı�����ִ�����²���
            if i_epoch > 0 and (i_epoch % c.SAVE_freq) == 0:
                # ��������123��Ȩ�غ��Ż���״̬
                torch.save({'opt': optim1.state_dict(),
                            'net': net1.state_dict()}, c.MODEL_PATH + 'model_checkpoint_%.5i_1' % i_epoch + '.pt')
                torch.save({'opt': optim2.state_dict(),
                            'net': net2.state_dict()}, c.MODEL_PATH + 'model_checkpoint_%.5i_2' % i_epoch + '.pt')
                torch.save({'opt': optim3.state_dict(),
                            'net': net3.state_dict()}, c.MODEL_PATH + 'model_checkpoint_%.5i_3' % i_epoch + '.pt')
            # ��������1��ѧϰ�ʵ�����
            weight_scheduler1.step()
            weight_scheduler2.step()
            weight_scheduler3.step()

        # �������յ�ѵ��ģ��
        torch.save({'opt': optim1.state_dict(),
                    'net': net1.state_dict()}, c.MODEL_PATH + 'model_1' + '.pt')
        torch.save({'opt': optim2.state_dict(),
                    'net': net2.state_dict()}, c.MODEL_PATH + 'model_2' + '.pt')
        torch.save({'opt': optim3.state_dict(),
                    'net': net3.state_dict()}, c.MODEL_PATH + 'model_3' + '.pt')
        writer.close()

    # �����κη������쳣
    except:
        if c.checkpoint_on_error:
            # ��������123��Ȩ�غ��Ż���״̬Ϊ 'model_ABORT_123'
            torch.save({'opt': optim1.state_dict(),
                        'net': net1.state_dict()}, c.MODEL_PATH + 'model_ABORT_1' + '.pt')
            torch.save({'opt': optim2.state_dict(),
                        'net': net2.state_dict()}, c.MODEL_PATH + 'model_ABORT_2' + '.pt')
            torch.save({'opt': optim3.state_dict(),
                        'net': net3.state_dict()}, c.MODEL_PATH + 'model_ABORT_3' + '.pt')
        raise

    finally:
        viz.signal_stop()
